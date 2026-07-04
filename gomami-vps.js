/**
 * GoMami VPS 面板脚本 (Surge generic panel)
 * 通过 VirtFusion 端用户 API 展示每台机器的：运行状态 / 本月流量用量 / 流量重置倒计时 / (可选) 手动续费到期倒计时。
 *
 * API base: https://cp.gomami.io/api
 *   - GET /server?results=200          机器列表 (名称/配额 limit/月度周期/IP)
 *   - GET /server/{uuid}?state=true    单机实时状态 (traffic.total 已用字节 / 电源 / CPU%)
 *
 * 关键点：cp.gomami.io 在 Cloudflare 后面，对「无浏览器 UA」的请求发 JS 挑战 (403)。
 *         只要带一个浏览器 User-Agent，GET 就能直接通过 → 见 UA 常量。
 *
 * ⚠️ 到期：VirtFusion 端用户 API 不暴露任何续费/到期字段（只有流量月度周期 currentMonthlyPeriod）。
 *         如需真实「到期倒计时」，用 EXPIRY 参数手动填每台机器的到期日（见 .sgmodule 说明）。
 *
 * token 只从 Surge 模块参数读取，不写死在本文件里。
 */

// cp.gomami.io Cloudflare 需要浏览器 UA 才放行（否则 403 挑战页）
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
const API_BASE = "https://cp.gomami.io/api";
const GiB = 1073741824; // 1024^3

// ============ 参数解析 ============
function getArgs() {
  const raw = typeof $argument !== "undefined" ? $argument : "";
  // Surge 对 {{{ARG}}} 是字面替换（不做 URL 编码），所以按 & 拆分后直接取值、不 decode。
  const p = Object.fromEntries(
    raw.split("&").map((kv) => {
      const [k, ...v] = kv.split("=");
      return [k.trim(), v.join("=").trim()];
    })
  );
  return {
    token: p.TOKEN || "",
    title: p.TITLE || "☁️ GoMami VPS",
    icon: p.ICON || "server.rack",
    iconColor: p.ICON_COLOR || "#30B0C7",
    showBar: p.SHOW_BAR !== "0",
    showCpu: p.SHOW_CPU === "1",
    showIp: p.SHOW_IP === "1",
    // 手动到期表: "HKG.Turin.Mini=2026-12-31,LAX.Pulse.Nano=2026-07-18"
    expiry: parseExpiry(p.EXPIRY || ""),
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
        headers: {
          Authorization: "Bearer " + token,
          Accept: "application/json",
          "User-Agent": UA,
        },
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
  if (g >= 1024) return (g / 1024).toFixed(2) + "T"; // 真 TiB
  if (g >= 100) return g.toFixed(0) + "G";
  if (g >= 10) return g.toFixed(1) + "G";
  return g.toFixed(2) + "G";
}

function bar(pct, n = 10) {
  const f = Math.max(0, Math.min(n, Math.round((pct / 100) * n)));
  return "▕" + "■".repeat(f) + "□".repeat(n - f) + "▏";
}

function statusEmoji(s) {
  if (s.suspended) return "⚠️";
  if (s.running) return "🟢";
  if (s.status === "stopped" || s.running === false) return "🔴";
  return "⚪";
}

function daysUntil(iso) {
  if (!iso) return null;
  const t = Date.parse(iso);
  if (isNaN(t)) return null;
  return Math.ceil((t - Date.now()) / 86400000);
}

// 解析配额字符串 "1000 GB" → GiB 数（VirtFusion 的 "GB" 实为 GiB，见 API 文档）
function parseLimitGiB(limit) {
  if (typeof limit !== "string") return null;
  const m = /^([\d.]+)\s*GB$/i.exec(limit.trim());
  return m ? parseFloat(m[1]) : null;
}

// ============ 主逻辑 ============
async function main() {
  const a = getArgs();

  if (!a.token) {
    return $done({
      title: "GoMami ⚠️ 未配置",
      content: "请在模块参数 TOKEN 里填入 gomami API token\n（在 cp.gomami.io/account/api 生成）",
      icon: "exclamationmark.triangle",
      "icon-color": "#FF9500",
    });
  }

  try {
    const listResp = await httpGet("/server?results=200", a.token, a.timeout);
    const servers = (listResp && listResp.data) || [];
    if (!servers.length) {
      return $done({
        title: a.title,
        content: "账户下没有服务器",
        icon: a.icon,
        "icon-color": a.iconColor,
      });
    }

    // 并发拉每台机器的实时状态（流量在这里）
    const details = await Promise.all(
      servers.map((s) =>
        httpGet("/server/" + encodeURIComponent(s.id) + "?state=true", a.token, a.timeout)
          .then((r) => (r && r.data) || null)
          .catch(() => null)
      )
    );

    const lines = [];
    let worst = 0; // 0 正常 / 1 提醒 / 2 危险 → 决定面板配色
    let sumUsed = 0;

    for (let i = 0; i < servers.length; i++) {
      const base = servers[i];
      const d = details[i] || base;
      const st = d.state || {};
      const name = base.name || "server";
      // 面板显示名：去掉冗余的 "GoMami " 前缀，避免手机面板换行（EXPIRY 匹配仍用原始 name）
      const disp = name.replace(/^GoMami\s+/i, "");

      const usedBytes = st.network?.primary?.traffic?.total ?? null;
      const usedGiB = usedBytes == null ? null : usedBytes / GiB;
      if (usedGiB != null) sumUsed += usedGiB;
      const allowGiB = parseLimitGiB(base.network?.primary?.limit);
      const pct = usedGiB != null && allowGiB ? (usedGiB / allowGiB) * 100 : null;

      const emoji = statusEmoji({
        suspended: base.suspended,
        running: st.running,
        status: st.status,
      });
      if (base.suspended) worst = Math.max(worst, 2);
      if (pct != null && pct >= 90) worst = Math.max(worst, 2);
      else if (pct != null && pct >= 75) worst = Math.max(worst, 1);

      // 第 1 行：状态 + 名称 + 流量
      let l1 = `${emoji} ${disp}`;
      if (usedGiB != null) {
        l1 += `  ${fmtG(usedGiB)}`;
        if (allowGiB) l1 += `/${fmtG(allowGiB)}`;
        if (pct != null) l1 += ` ${pct.toFixed(pct < 10 ? 1 : 0)}%`;
      }
      lines.push(l1);

      // 第 2 行：进度条 + 流量重置 + (到期) + (CPU) + (IP)
      const seg = [];
      if (a.showBar && pct != null) seg.push(bar(pct));
      const resetD = daysUntil(base.currentMonthlyPeriod?.end);
      if (resetD != null) seg.push(`↺${resetD}d`);

      const exp = a.expiry[name] || a.expiry[disp]; // 原始名或去前缀的显示名都能匹配
      if (exp) {
        const ed = daysUntil(exp + "T23:59:59Z");
        if (ed != null) {
          seg.push(`⏳${ed}d`);
          if (ed <= 0) worst = Math.max(worst, 2);
          else if (ed <= a.expiryWarn) worst = Math.max(worst, 2);
          else if (ed <= a.expiryWarn * 3) worst = Math.max(worst, 1);
        }
      }
      if (a.showCpu && st.cpu) seg.push(`🖥${String(st.cpu).replace(/\s/g, "")}`);
      if (a.showIp) {
        const ip = base.network?.primary?.ipv4?.[0]?.address;
        if (ip) seg.push(ip);
      }
      if (seg.length) lines.push("   " + seg.join(" · "));
    }

    // 汇总标题
    const title = `${a.title}  ·  ${servers.length}台 · Σ${fmtG(sumUsed)}`;
    const color = worst === 2 ? "#FF3B30" : worst === 1 ? "#FF9500" : a.iconColor;
    const icon = worst === 2 ? "exclamationmark.triangle.fill" : a.icon;

    $done({
      title,
      content: lines.join("\n"),
      icon,
      "icon-color": color,
    });
  } catch (e) {
    $done({
      title: "GoMami ❌",
      content: `查询失败: ${e.message || e}`,
      icon: "xmark.octagon",
      "icon-color": "#FF3B30",
    });
  }
}

main();
