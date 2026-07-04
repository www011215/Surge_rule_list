/**
 * GoMami VPS 面板脚本 (Surge generic panel)
 * 展示每台机器：状态点 + 机器名 / IP + CPU / 流量用量 / 斜杠进度条(+流量重置、可选到期倒计时)。
 *
 * API base: https://cp.gomami.io/api
 *   - GET /server?results=200          机器列表 (名称/配额 limit/月度周期/IP)
 *   - GET /server/{uuid}?state=true    单机实时状态 (traffic.total 已用字节 / 电源 / CPU%)
 *
 * cp.gomami.io 在 Cloudflare 后面：请求必须带浏览器 UA（否则 403 挑战页），带上 GET 就能过。
 * 到期：VirtFusion API 不提供续费到期，只有流量月度周期；到期用 EXPIRY 参数手动填。
 * token 只从 Surge 模块参数读取，不写死。
 */

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const API_BASE = "https://cp.gomami.io/api";
const GiB = 1073741824;
const TOKEN_PLACEHOLDER = "PASTE_YOUR_TOKEN";

// 机场/机房位置码 -> 地区名（标题里显示 HK · US 这种）
const REGION = {
  HKG: "HK", HK: "HK",
  LAX: "US", LAS: "US", SJC: "US", SFO: "US", SEA: "US", PDX: "US", NYC: "US",
  EWR: "US", ORD: "US", DFW: "US", MIA: "US", ATL: "US", IAD: "US", CHI: "US",
  DAL: "US", BUF: "US", LA: "US", US: "US",
  NRT: "JP", HND: "JP", KIX: "JP", TYO: "JP", JP: "JP",
  SIN: "SG", SG: "SG",
  LON: "UK", LHR: "UK", UK: "UK", GB: "UK",
  FRA: "DE", DE: "DE", AMS: "NL", NL: "NL",
  ICN: "KR", SEL: "KR", KR: "KR",
  TPE: "TW", TW: "TW", SYD: "AU", AU: "AU",
};

// ============ 参数解析 ============
function getArgs() {
  const raw = typeof $argument !== "undefined" ? $argument : "";
  // Surge 对 {{{ARG}}} 是字面替换；顺手剥掉 #!arguments 里 "..." 可能残留的包裹引号。
  const p = Object.fromEntries(
    raw.split("&").map((kv) => {
      const [k, ...v] = kv.split("=");
      return [k.trim(), v.join("=").trim().replace(/^"([\s\S]*)"$/, "$1")];
    })
  );
  const rawToken = p.TOKEN || "";
  const rawExpiry = p.EXPIRY || "";
  return {
    token: rawToken === TOKEN_PLACEHOLDER ? "" : rawToken,
    title: p.TITLE || "GoMAMi",
    icon: p.ICON || "cloud",
    iconColor: p.ICON_COLOR || "#000000",
    showBar: p.SHOW_BAR !== "0",
    showSpec: p.SHOW_SPEC !== "0", // CPU/RAM 配置，默认开
    showIp: p.SHOW_IP !== "0",     // 默认开
    expiry: parseExpiry(rawExpiry === "none" ? "" : rawExpiry),
    expiryWarn: parseInt(p.EXPIRY_WARN) || 7,
    timeout: parseInt(p.TIMEOUT) || 15,
  };
}

function parseExpiry(s) {
  const map = {};
  if (!s) return map;
  for (const pair of s.split(",")) {
    const i = pair.lastIndexOf("=");
    if (i < 0) continue;
    const name = pair.slice(0, i).trim();
    const date = pair.slice(i + 1).trim();
    if (name && date) map[name] = date;
  }
  return map;
}

// ============ HTTP ============
function httpGet(path, token, timeout) {
  return new Promise((resolve, reject) => {
    $httpClient.get(
      {
        url: API_BASE + path,
        timeout: timeout * 1000,
        headers: { Authorization: "Bearer " + token, Accept: "application/json", "User-Agent": UA },
      },
      (err, resp, body) => {
        if (err) return reject(new Error(String(err)));
        const status = resp ? (resp.status ?? resp.statusCode ?? 0) : 0;
        if (status === 401) return reject(new Error("401 token 无效或过期"));
        if (status === 403) return reject(new Error("403 被 Cloudflare 拦截"));
        if (status === 429) return reject(new Error("429 请求过于频繁"));
        if (status >= 400) return reject(new Error(status + " API 错误"));
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(new Error("JSON 解析失败"));
        }
      }
    );
  });
}

// ============ 格式化 ============
function fmtG(g) {
  if (g >= 1024) return (g / 1024).toFixed(2) + "T";
  if (g >= 100) return g.toFixed(0) + "G";
  if (g >= 10) return g.toFixed(1) + "G";
  return g.toFixed(2) + "G";
}

// 粗轨道进度条：已用 = "━"(粗线)，剩余 = "─"(细线)，两端无端盖，等宽比例忠实
function bar(pct, n = 16) {
  const f = Math.max(0, Math.min(n, Math.round((pct / 100) * n)));
  return "━".repeat(f) + "─".repeat(n - f);
}

// 日期 MM-DD（用 UTC，匹配 API 的月末时间）
function fmtDate(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (isNaN(t)) return null;
  const d = new Date(t);
  return String(d.getUTCMonth() + 1).padStart(2, "0") + "-" + String(d.getUTCDate()).padStart(2, "0");
}

// 机器配置：核数 + 内存，如 "2C · 4GB"
function fmtSpec(base) {
  const parts = [];
  const c = /(\d+)/.exec(base.cpu || "");
  if (c) parts.push(c[1] + "C");
  const mm = /(\d+)/.exec(base.memory || "");
  if (mm) {
    const mb = parseInt(mm[1]);
    parts.push(mb % 1024 === 0 ? mb / 1024 + "GB" : mb >= 1024 ? (mb / 1024).toFixed(1) + "GB" : mb + "MB");
  }
  return parts.join(" · ");
}

// 黑色小方块状态点（不用彩色圆点）
function statusDot(s) {
  if (s.suspended) return "▨"; // 暂停
  if (s.running) return "▪";   // 运行
  if (s.status === "stopped" || s.running === false) return "▫"; // 关机(空心)
  return "▪";
}

function daysUntil(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (isNaN(t)) return null;
  return Math.ceil((t - Date.now()) / 86400000);
}

function parseLimitGiB(limit) {
  if (typeof limit !== "string") return null;
  const m = /^([\d.]+)\s*GB$/i.exec(limit.trim());
  return m ? parseFloat(m[1]) : null;
}

function dispName(name) {
  return name.replace(/^GoMami\s+/i, "");
}

function regionOf(name) {
  const code = dispName(name).split(".")[0].toUpperCase();
  return REGION[code] || code;
}

// ============ 主逻辑 ============
async function main() {
  const a = getArgs();

  if (!a.token) {
    return $done({
      title: "GoMAMi ⚠️ 未配置",
      content: "请在模块参数 TOKEN 里填入 gomami API token\n（把 PASTE_YOUR_TOKEN 替换成 cp.gomami.io/account/api 生成的 token）",
      icon: "exclamationmark.triangle",
      "icon-color": "#FF9500",
    });
  }

  try {
    const listResp = await httpGet("/server?results=200", a.token, a.timeout);
    const servers = (listResp && listResp.data) || [];
    if (!servers.length) {
      return $done({ title: a.title, content: "账户下没有服务器", icon: a.icon, "icon-color": a.iconColor });
    }

    const details = await Promise.all(
      servers.map((s) =>
        httpGet("/server/" + encodeURIComponent(s.id) + "?state=true", a.token, a.timeout)
          .then((r) => (r && r.data) || null)
          .catch(() => null)
      )
    );

    const blocks = [];
    const regions = [];
    let worst = 0;

    for (let i = 0; i < servers.length; i++) {
      const base = servers[i];
      const d = details[i] || base;
      const st = d.state || {};
      const disp = dispName(base.name || "server");

      const reg = regionOf(base.name || "");
      if (!regions.includes(reg)) regions.push(reg);

      const usedBytes = st.network?.primary?.traffic?.total ?? null;
      const usedGiB = usedBytes == null ? null : usedBytes / GiB;
      const allowGiB = parseLimitGiB(base.network?.primary?.limit);
      const pct = usedGiB != null && allowGiB ? (usedGiB / allowGiB) * 100 : null;

      if (base.suspended) worst = Math.max(worst, 2);
      if (pct != null && pct >= 90) worst = Math.max(worst, 2);
      else if (pct != null && pct >= 75) worst = Math.max(worst, 1);

      const dot = statusDot({ suspended: base.suspended, running: st.running, status: st.status });
      const lines = [];

      // 1) 机器名单独一行
      lines.push(`${dot} ${disp}`);

      // 2) IP（+ CPU/RAM 配置）
      const ip = base.network?.primary?.ipv4?.[0]?.address;
      const spec = fmtSpec(base);
      const l2 = [];
      if (a.showIp && ip) l2.push(ip);
      if (a.showSpec && spec) l2.push(spec);
      if (l2.length) lines.push("  " + l2.join("   "));

      // 3) 流量
      let l3 = "  ";
      if (usedGiB != null) {
        l3 += `${fmtG(usedGiB)}`;
        if (allowGiB) l3 += ` / ${fmtG(allowGiB)}`;
        if (pct != null) l3 += ` · ${pct.toFixed(pct < 10 ? 1 : 0)}%`;
      } else {
        l3 += "流量数据不可用";
      }

      // 时间信息（流量重置日期 / 到期）
      const info = [];
      const resetDate = fmtDate(base.currentMonthlyPeriod?.end);
      if (resetDate) info.push(resetDate);
      const exp = a.expiry[base.name] || a.expiry[disp];
      if (exp) {
        const ed = daysUntil(exp + "T23:59:59Z");
        if (ed != null) {
          info.push(`⏳${ed}d`);
          if (ed <= a.expiryWarn) worst = Math.max(worst, 2);
          else if (ed <= a.expiryWarn * 3) worst = Math.max(worst, 1);
        }
      }

      // 4) 进度条（+时间信息）；若关进度条则把时间信息挂到流量行
      if (a.showBar && pct != null) {
        lines.push(l3);
        lines.push("  " + bar(pct) + (info.length ? "  " + info.join(" · ") : ""));
      } else {
        lines.push(l3 + (info.length ? "  " + info.join(" · ") : ""));
      }

      blocks.push(lines.join("\n"));
    }

    // 标题：GoMAMi · HK · US （不显示台数/总流量）
    const title = regions.length ? `${a.title} · ${regions.join(" · ")}` : a.title;
    const color = worst === 2 ? "#FF3B30" : worst === 1 ? "#FF9500" : a.iconColor;

    $done({
      title,
      content: blocks.join("\n\n"), // 机器之间空一行
      icon: a.icon,
      "icon-color": color,
    });
  } catch (e) {
    $done({
      title: "GoMAMi ❌",
      content: `查询失败: ${e.message || e}`,
      icon: "xmark.octagon",
      "icon-color": "#FF3B30",
    });
  }
}

main();
