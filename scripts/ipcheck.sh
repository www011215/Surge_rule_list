#!/usr/bin/env bash
# ipcheck.sh — focused IP-quality + streaming-region checker
#
# Designed for VPS used as a proxy egress (snell / shadowsocks / etc).
# Tests v4 AND v6 paths separately, then verifies any active smartdns
# IP-family-forcing rules (Meta→v6, Google→v4) are working.
#
# Run on the egress VPS:
#   bash <(curl -fsSL https://raw.githubusercontent.com/www011215/Surge_rule_list/main/scripts/ipcheck.sh)
#
# Flags:
#   -4   only test IPv4 path
#   -6   only test IPv6 path
#   -s   short output (skip DNS-rule verification)
#
# Dependencies: bash, curl, dig, python3 (all standard on Debian/Ubuntu/RHEL).
# Source: github.com/www011215/Surge_rule_list

set -u
MODE="A"; SHORT=0
while getopts "46s" o; do case "$o" in 4) MODE=4;; 6) MODE=6;; s) SHORT=1;; esac; done

# --- colors (auto-disable when piped) -----------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; D=""
fi

hdr()  { printf "\n${B}══ %s ══${D}\n" "$1"; }
ok()   { printf " ${G}✓${D}  %-22s %s\n" "$1" "$2"; }
warn() { printf " ${Y}!${D}  %-22s %s\n" "$1" "$2"; }
bad()  { printf " ${R}✗${D}  %-22s %s\n" "$1" "$2"; }
info() { printf "    %-22s %s\n" "$1" "$2"; }

# --- helpers ------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
fail_deps=""
for c in curl dig python3; do have $c || fail_deps="$fail_deps $c"; done
if [ -n "$fail_deps" ]; then
  echo "missing tools:$fail_deps" >&2; exit 2
fi

# Resolve AAAA via 1.1.1.1, following CNAME once (bypasses any local AAAA filter)
resolve_aaaa() {
  local h=$1 r cn
  r=$(dig @1.1.1.1 AAAA "$h" +short 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -1)
  if [ -z "$r" ]; then
    cn=$(dig @1.1.1.1 AAAA "$h" +short 2>/dev/null | grep -E '\.$' | head -1)
    [ -n "$cn" ] && r=$(dig @1.1.1.1 AAAA "$cn" +short 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -1)
  fi
  echo "$r"
}

# JSON field extractor (python3 inline)
jget() { python3 -c "import sys,json;
try: d=json.loads(sys.stdin.read()); print(d.get('$1',''))
except: pass"; }

# curl with family selector
fetch() { # $1=family(4/6) $2=url [extra args...]
  local f=$1; shift; local url=$1; shift
  if [ "$f" = "4" ]; then curl -4 -s -m 10 -A "Mozilla/5.0" "$@" "$url"
  else                    curl -6 -s -m 10 -A "Mozilla/5.0" "$@" "$url"
  fi
}

# Has v6 connectivity?
have_v6() { curl -6 -s -m 4 -o /dev/null -w "%{http_code}" https://[2606:4700:4700::1111]/ 2>/dev/null | grep -qE '^[2-4][0-9][0-9]$'; }

# ============================================================================
hdr "ipcheck v1.0  ·  $(date '+%F %T %Z')  ·  $(hostname)"

V6_OK=0; have_v6 && V6_OK=1
[ "$MODE" = "A" ] || echo "(mode: v${MODE} only)"
if [ $V6_OK -eq 0 ] && { [ "$MODE" = "A" ] || [ "$MODE" = "6" ]; }; then
  warn "IPv6" "no global IPv6 connectivity (will skip v6 tests)"
  [ "$MODE" = "6" ] && exit 1
  MODE=4
fi

# ============================================================================
hdr "Identity (who do remote sites see you as?)"

run_ip() {
  local f=$1
  # Step 1: discover own IP. ifconfig.co returns HTML to browsers; force the /ip
  # endpoint which is always plain text.
  local ip=$(fetch $f https://ifconfig.co/ip 2>/dev/null | tr -d '[:space:]')
  if [ -z "$ip" ]; then
    bad "v${f} IP info"  "(no outbound v${f})"
    return
  fi
  # Step 2: lookup that IP's geo via ipinfo (do this over v4 — ipinfo.io v4 has a more reliable lookup endpoint for any address family)
  local j=$(curl -4 -s -m 6 "https://ipinfo.io/${ip}/json" 2>/dev/null)
  if [ -z "$j" ] || ! echo "$j" | python3 -c "import sys,json;json.load(sys.stdin)" 2>/dev/null; then
    ok   "v${f} IP"  "$ip"
    info "  geo"     "(ipinfo lookup failed)"
    return
  fi
  local city=$(echo "$j" | jget city)
  local region=$(echo "$j" | jget region)
  local cc=$(echo "$j" | jget country)
  local org=$(echo "$j" | jget org)
  local loc=$(echo "$j" | jget loc)
  ok   "v${f} IP"           "$ip"
  info "  geo"              "$city, $region, $cc  ($loc)"
  info "  ASN"              "$org"
}
[ "$MODE" != "6" ] && run_ip 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && run_ip 6

# ============================================================================
hdr "Streaming region (YouTube • Netflix • Spotify • OpenAI)"

# --- YouTube --------------------------------------------------------
test_youtube() {
  local f=$1 body extra=""
  if [ $f = 6 ]; then
    local ip=$(resolve_aaaa youtube-ui.l.google.com)
    [ -z "$ip" ] && { bad "v6 YouTube" "no AAAA upstream"; return; }
    extra="--resolve www.youtube.com:443:[$ip]"
  fi
  body=$(fetch $f https://www.youtube.com/ $extra)
  local gl=$(echo "$body" | grep -oE '"INNERTUBE_CONTEXT_GL":"[^"]+"' | head -1 | cut -d'"' -f4)
  local cdn=$(echo "$body" | grep -oE 'rr[0-9]+---sn-[a-z0-9]+\.googlevideo\.com' | head -1 | sed 's/.*sn-//')
  if [ -z "$gl" ]; then bad "v${f} YouTube" "(no region parsed; likely blocked)"
  elif [ "$gl" = "US" ]; then ok "v${f} YouTube" "GL=$gl${cdn:+   CDN sn-$cdn}"
  elif [ "$gl" = "CN" ]; then bad "v${f} YouTube" "GL=$gl ← geo-mislabeled (送中)"
  else warn "v${f} YouTube" "GL=$gl"
  fi
}
[ "$MODE" != "6" ] && test_youtube 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_youtube 6

# --- Netflix --------------------------------------------------------
# title 81280792 = Squid Game S2 (US-licensed); CN catalog doesn't have Netflix at all
test_netflix() {
  local f=$1 extra=""
  if [ $f = 6 ]; then
    local ip=$(resolve_aaaa www.netflix.com)
    [ -z "$ip" ] && { bad "v6 Netflix" "no AAAA upstream"; return; }
    extra="--resolve www.netflix.com:443:[$ip]"
  fi
  local code=$(fetch $f https://www.netflix.com/title/81280792 $extra -L -o /dev/null -w '%{http_code}')
  case "$code" in
    200) ok   "v${f} Netflix" "200 OK (US catalog reachable)" ;;
    403) bad  "v${f} Netflix" "403 (proxy detected / region-blocked)" ;;
    *)   warn "v${f} Netflix" "HTTP $code" ;;
  esac
}
[ "$MODE" != "6" ] && test_netflix 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_netflix 6

# --- Disney+ region (use the title page; their gateway honors XX-Forwarded-For) ----
test_disney() {
  local f=$1 extra=""
  if [ $f = 6 ]; then
    local ip=$(resolve_aaaa www.disneyplus.com)
    [ -z "$ip" ] && { warn "v6 Disney+" "no AAAA upstream"; return; }
    extra="--resolve www.disneyplus.com:443:[$ip]"
  fi
  # /login redirects to the region-localised marketing page if region is allowed,
  # or to /unavailable when blocked
  local final=$(fetch $f https://www.disneyplus.com/login $extra -L -o /dev/null -w '%{url_effective}')
  case "$final" in
    *unavailable*)         bad  "v${f} Disney+" "unavailable in region" ;;
    *disneyplus.com/login*|*disneyplus.com/welcome*|*disneyplus.com/sign-up*|*disneyplus.com/home*)
                            ok   "v${f} Disney+" "OK ($(echo "$final" | grep -oE 'disneyplus\.com/[^/]+/' | head -1 | tr -d /))" ;;
    "")                     warn "v${f} Disney+" "(empty response)" ;;
    *)                      ok   "v${f} Disney+" "OK" ;;
  esac
}
[ "$MODE" != "6" ] && test_disney 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_disney 6

# --- OpenAI/ChatGPT region (CloudFront edge POP) ------------------------------
test_openai() {
  local f=$1
  local geo=$(fetch $f https://chat.openai.com/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2)
  local restrict=$(fetch $f https://chat.openai.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=|^gateway=')
  if [ -n "$geo" ]; then ok "v${f} ChatGPT" "loc=$geo"
  else warn "v${f} ChatGPT" "(no loc returned)"
  fi
}
[ "$MODE" != "6" ] && test_openai 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_openai 6

# ============================================================================
[ $SHORT -eq 1 ] && exit 0
hdr "Local DNS rule verification  (smartdns force-family rules)"

if ! dig @127.0.0.1 . SOA +time=1 +tries=1 +short > /dev/null 2>&1; then
  warn "smartdns" "127.0.0.1:53 not responding — skipping rule audit"
  exit 0
fi

# Domains that SHOULD be forced to v6 only (A empty, AAAA present)
META=(www.facebook.com www.instagram.com www.threads.net www.whatsapp.com www.fbsbx.com graph.facebook.com)
# Domains that SHOULD be forced to v4 only (AAAA empty, A present)
GOOG=(www.youtube.com www.google.com i.ytimg.com lh3.googleusercontent.com)

probe() { # $1=domain  → echoes "A:<val> AAAA:<val>"
  local d=$1
  local a=$(dig @127.0.0.1 A "$d" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  local aaaa=$(dig @127.0.0.1 AAAA "$d" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -1)
  echo "${a:-_} ${aaaa:-_}"
}

echo "  Meta domains (expect: A empty, AAAA present → force v6):"
for d in "${META[@]}"; do
  read a aaaa < <(probe "$d")
  if [ "$a" = "_" ] && [ "$aaaa" != "_" ]; then
    ok "$d" "→ $aaaa"
  elif [ "$a" != "_" ] && [ "$aaaa" != "_" ]; then
    warn "$d" "BOTH A=$a + AAAA=$aaaa  (rule not applied?)"
  elif [ "$a" != "_" ]; then
    bad "$d" "A=$a, no AAAA (going via v4!)"
  else
    bad "$d" "no records at all"
  fi
done

echo
echo "  Google domains (expect: A present, AAAA empty → force v4):"
for d in "${GOOG[@]}"; do
  read a aaaa < <(probe "$d")
  if [ "$a" != "_" ] && [ "$aaaa" = "_" ]; then
    ok "$d" "→ $a"
  elif [ "$a" != "_" ] && [ "$aaaa" != "_" ]; then
    warn "$d" "BOTH A=$a + AAAA=$aaaa  (rule not applied?)"
  elif [ "$aaaa" != "_" ]; then
    bad "$d" "AAAA=$aaaa, no A (going via v6!)"
  else
    bad "$d" "no records at all"
  fi
done

echo
hdr "Done · re-run anytime: bash <(curl -fsSL https://raw.githubusercontent.com/www011215/Surge_rule_list/main/scripts/ipcheck.sh)"
