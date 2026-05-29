#!/usr/bin/env bash
# ipcheck.sh — focused IP-quality + streaming-region checker
#
# Designed for VPS used as a proxy egress (snell / shadowsocks / etc).
# Tests v4 AND v6 paths separately, then runs a ROLE-AWARE DNS audit:
#   - on an unlock CLIENT  : checks AI/Google/Meta rewrite to the egress IP
#   - on the unlock EGRESS : checks smartdns force-family rules (Meta v6, Google v4)
# Auto-detects role and the egress IP at runtime (no hardcoded addresses).
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
hdr "ipcheck v1.3  ·  $(date '+%F %T %Z')  ·  $(hostname)"

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
  if [ -z "$gl" ]; then bad "v${f} YouTube GL" "(no region parsed; likely blocked)"
  elif [ "$gl" = "US" ]; then ok "v${f} YouTube GL" "GL=$gl${cdn:+   CDN sn-$cdn}"
  elif [ "$gl" = "CN" ]; then bad "v${f} YouTube GL" "GL=$gl ← geo-mislabeled (送中)"
  else warn "v${f} YouTube GL" "GL=$gl"
  fi
}
[ "$MODE" != "6" ] && test_youtube 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_youtube 6

# --- YouTube Premium availability ---------------------------------------------
# The DEFINITIVE signal. Premium uses a SEPARATE, stricter geo database than the
# homepage GL — an IP can show GL=US yet still fail Premium ("not available in
# your country"). This is exactly what bit the Cox v6 prefix: GL=US but Premium
# rejected. Always trust this over the GL field above.
test_yt_premium() {
  local f=$1 extra=""
  if [ $f = 6 ]; then
    local ip=$(resolve_aaaa www.youtube.com)
    [ -z "$ip" ] && { bad "v6 YT Premium" "no AAAA upstream"; return; }
    extra="--resolve www.youtube.com:443:[$ip]"
  fi
  local page=$(fetch $f https://www.youtube.com/premium $extra)
  if echo "$page" | grep -qiE "not available in your (country|location|region)|isn.t available in your"; then
    bad  "v${f} YT Premium" "NOT available ← Premium geo rejects this IP (送中)"
  elif echo "$page" | grep -qiE "INNERTUBE_CONTEXT_GL"; then
    ok   "v${f} YT Premium" "available (no region rejection)"
  else
    warn "v${f} YT Premium" "(could not determine)"
  fi
}
[ "$MODE" != "6" ] && test_yt_premium 4
[ "$MODE" != "4" ] && [ $V6_OK -eq 1 ] && test_yt_premium 6

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
hdr "AI services (Claude · ChatGPT · Gemini · Meta AI)"
# Cloudflare-fronted AIs expose /cdn-cgi/trace → the exit IP the service actually
# sees (→ v4/v6 family) + its geo region. Family is left to the OS so this reflects
# the real egress→AI leg (e.g. wave's ipv6_first), not the client→egress hop.

aitrace() { curl -s -m 12 -A "Mozilla/5.0" -H 'Accept-Language: en-US,en;q=0.9' "https://$1/cdn-cgi/trace" 2>/dev/null; }
famof() { case "$1" in *:*) echo v6;; ?*) echo v4;; *) echo "?";; esac; }

ai_cf() { # $1=label $2=host
  local t ip loc colo
  t=$(aitrace "$2")
  ip=$(echo "$t"  | awk -F= '/^ip=/{print $2}')
  loc=$(echo "$t" | awk -F= '/^loc=/{print $2}')
  colo=$(echo "$t"| awk -F= '/^colo=/{print $2}')
  if [ -z "$ip" ]; then bad "$1" "unreachable (no trace)"; return; fi
  local msg="exit=$(famof "$ip")  region=$loc  CF=$colo  (seen-as $ip)"
  if [ "$loc" = "CN" ]; then bad "$1" "region=CN ← 送中!  $msg"
  else                       ok  "$1" "$msg"; fi
}

# --- Claude (priority) + ChatGPT — Cloudflare, full trace -----------------
ai_cf "Claude API"  api.anthropic.com
ai_cf "Claude.ai"   claude.ai
ai_cf "ChatGPT web" chat.openai.com

# --- ChatGPT availability (OpenAI compliance endpoint) --------------------
cc=$(curl -s -m 10 -A "Mozilla/5.0" https://api.openai.com/compliance/cookie_requirements 2>/dev/null)
if   echo "$cc" | grep -qi "unsupported_country"; then bad  "ChatGPT avail" "unsupported_country (blocked at this exit)"
elif [ -n "$cc" ];                                 then ok  "ChatGPT avail" "supported region"
else                                                    warn "ChatGPT avail" "(no signal)"; fi

# --- Claude availability (claude.ai app vs geo-block) ---------------------
cl=$(curl -s -m 10 -A "Mozilla/5.0" -H 'Accept-Language: en-US,en;q=0.9' https://claude.ai/ 2>/dev/null)
if   echo "$cl" | grep -qiE "not available in your|isn't available|app-unavailable"; then bad  "Claude avail" "geo-blocked at this exit"
elif echo "$cl" | grep -qiE "claude|anthropic"; then ok  "Claude avail" "reachable (app served)"
else                                                  warn "Claude avail" "(could not determine)"; fi

# --- Gemini (Google; not Cloudflare) — reachability + region best-effort --
gtmp=$(curl -s -m 10 -A "Mozilla/5.0" -H 'Accept-Language: en-US,en;q=0.9' -w '\n__C__%{http_code}' https://gemini.google.com/app 2>/dev/null)
gcode=${gtmp##*__C__}; gbody=${gtmp%$'\n'__C__*}
if   echo "$gbody" | grep -qiE "not available in your (country|region)|isn't available"; then bad  "Gemini" "not available in region"
elif [ "$gcode" = "200" ] || [ "$gcode" = "302" ] || [ "$gcode" = "303" ];               then ok   "Gemini" "reachable (HTTP $gcode)"
else                                                                                           warn "Gemini" "HTTP $gcode (login/region wall — inconclusive)"; fi

# --- Meta AI (Meta; not Cloudflare) — only select regions -----------------
mtmp=$(curl -s -m 10 -A "Mozilla/5.0" -H 'Accept-Language: en-US,en;q=0.9' -w '\n__C__%{http_code}' https://www.meta.ai/ 2>/dev/null)
mcode=${mtmp##*__C__}; mbody=${mtmp%$'\n'__C__*}
if   echo "$mbody" | grep -qiE "not available|isn't available|not yet available|waitlist|unsupported"; then bad  "Meta AI" "not available in region"
elif [ "$mcode" = "200" ];                                                                             then ok   "Meta AI" "reachable (HTTP $mcode)"
else                                                                                                        warn "Meta AI" "HTTP $mcode (inconclusive)"; fi

info "note" "Claude/ChatGPT show the real exit family+region (CF trace);"
info ""     "Gemini/Meta AI are non-CF → reachability/region only (family set by egress policy)."

# ============================================================================
[ $SHORT -eq 1 ] && exit 0
hdr "Local DNS policy verification (role-aware)"

if ! dig @127.0.0.1 . SOA +time=1 +tries=1 +short > /dev/null 2>&1; then
  warn "smartdns" "127.0.0.1:53 not responding — skipping audit"
  exit 0
fi

probe() { # $1=domain -> "A AAAA"  ('_' when empty)
  local d=$1
  local a=$(dig @127.0.0.1 A "$d" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  local aaaa=$(dig @127.0.0.1 AAAA "$d" +short +time=2 +tries=1 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -1)
  echo "${a:-_} ${aaaa:-_}"
}

# --- Detect role from how the local resolver answers (no hardcoded IPs) -------
#   client : an unlock ORIGIN (AI/Google/Meta rewritten to one egress IP)
#   egress : the unlock EGRESS (smartdns force-family rules active: Meta v6, Google v4)
#   plain  : neither
read a1 _ < <(probe api.anthropic.com)
read a2 _ < <(probe chat.openai.com)
read fa faaaa < <(probe www.facebook.com)
ROLE=plain; UNLOCK_IP=""
if [ "$a1" != "_" ] && [ "$a1" = "$a2" ]; then
  ROLE=client; UNLOCK_IP=$a1
elif [ "$fa" = "_" ] && [ "$faaaa" != "_" ]; then
  ROLE=egress
fi
info "detected role" "$ROLE${UNLOCK_IP:+  (unlock egress = $UNLOCK_IP)}"

if [ "$ROLE" = "client" ]; then
  echo
  echo "  Unlocked domains (expect -> egress, A only; client->egress leg is v4 by design):"
  for d in api.anthropic.com chat.openai.com www.google.com drive.google.com \
           www.facebook.com www.instagram.com www.icloud.com music.apple.com; do
    read a aaaa < <(probe "$d")
    if   [ "$a" = "$UNLOCK_IP" ]; then ok   "$d" "-> egress"
    elif [ "$a" != "_" ];        then warn "$d" "-> $a (not unlocked)"
    else                              bad  "$d" "no A record"; fi
  done
  echo
  echo "  Deliberately NOT unlocked (expect real IP, HK direct):"
  for d in www.youtube.com i.ytimg.com; do
    read a aaaa < <(probe "$d")
    if   [ "$a" = "$UNLOCK_IP" ]; then bad "$d" "-> egress! (should be direct)"
    elif [ "$a" != "_" ];        then ok  "$d" "-> direct ($a)"
    else                              warn "$d" "no A"; fi
  done
  echo
  info "note" "A-only is CORRECT: client reaches egress over v4 (-> DNAT -> sniproxy)."
  info ""     "Any IPv6 selection happens on the egress->upstream leg, invisible here."
  echo
  echo "  Geo-mislabel (送中) check — does the egress pass YouTube Premium? (real signal):"
  if [ -n "$UNLOCK_IP" ]; then
    pg=$(curl -fsSL -m 15 -A "Mozilla/5.0" -H 'Accept-Language: en-US,en;q=0.9' \
         --resolve www.youtube.com:443:"$UNLOCK_IP" https://www.youtube.com/premium 2>/dev/null)
    if   echo "$pg" | grep -qiE "not available in your (country|location|region)|isn.t available in your"; then
      bad  "egress YT Premium" "NOT available <- egress 送中"
    elif echo "$pg" | grep -qiE "INNERTUBE_CONTEXT_GL"; then
      ok   "egress YT Premium" "available (egress not 送中)"
    else
      warn "egress YT Premium" "(could not determine)"
    fi
  fi

elif [ "$ROLE" = "egress" ]; then
  echo "  (smartdns force-family rules: Meta->v6, Google->v4)"
  META=(www.facebook.com www.instagram.com www.threads.net www.whatsapp.com www.fbsbx.com graph.facebook.com)
  GOOG=(www.youtube.com www.google.com i.ytimg.com lh3.googleusercontent.com)
  echo
  echo "  Meta domains (expect: A empty, AAAA present -> force v6):"
  for d in "${META[@]}"; do
    read a aaaa < <(probe "$d")
    if   [ "$a" = "_" ] && [ "$aaaa" != "_" ]; then ok   "$d" "-> $aaaa"
    elif [ "$a" != "_" ] && [ "$aaaa" != "_" ]; then warn "$d" "BOTH A=$a + AAAA=$aaaa (rule not applied?)"
    elif [ "$a" != "_" ];                       then bad  "$d" "A=$a, no AAAA (going via v4!)"
    else                                             bad  "$d" "no records"; fi
  done
  echo
  echo "  Google domains (expect: A present, AAAA empty -> force v4):"
  for d in "${GOOG[@]}"; do
    read a aaaa < <(probe "$d")
    if   [ "$a" != "_" ] && [ "$aaaa" = "_" ]; then ok   "$d" "-> $a"
    elif [ "$a" != "_" ] && [ "$aaaa" != "_" ]; then warn "$d" "BOTH A=$a + AAAA=$aaaa (rule not applied?)"
    elif [ "$aaaa" != "_" ];                    then bad  "$d" "AAAA=$aaaa, no A (v6 -> Premium 送中 risk!)"
    else                                             bad  "$d" "no records"; fi
  done

else
  warn "policy" "neither unlock-client nor force-family egress detected — skipping audit"
fi

echo
hdr "Done · re-run anytime: bash <(curl -fsSL https://raw.githubusercontent.com/www011215/Surge_rule_list/main/scripts/ipcheck.sh)"
