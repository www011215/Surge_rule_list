/**
 * IPPure 网络信息查询脚本
 * 适用于 Surge 面板 (generic) 和网络变化事件 (event)
 * API: https://my.ippure.com/v1/info
 */

const IPPURE_API = "https://my.ippure.com/v1/info";

// ============ 参数解析 ============
function getArgs() {
  const raw = typeof $argument !== "undefined" ? $argument : "";
  const params = Object.fromEntries(
    raw.split("&").map((p) => {
      const [k, ...v] = p.split("=");
      return [k.trim(), v.join("=").trim()];
    })
  );
  return {
    type: params.TYPE || "PANEL", // PANEL or EVENT
    flag: params.FLAG !== "0",
    asn: params.ASN !== "0",
    org: params.ORG !== "0",
    risk: params.RISK !== "0",
    residential: params.RESIDENTIAL !== "0",
    geo: params.GEO !== "0",
    mask: params.MASK === "1",
    timeout: parseInt(params.TIMEOUT) || 10,
    icon: params.ICON || "globe.asia.australia",
    iconColor: params.ICON_COLOR || "#6699FF",
    eventDelay: parseInt(params.EVENT_DELAY) || 3,
  };
}

// ============ 国旗 Emoji ============
function countryFlag(code) {
  if (!code || code.length !== 2) return "";
  return String.fromCodePoint(
    ...[...code.toUpperCase()].map((c) => 0x1f1e6 + c.charCodeAt(0) - 65)
  );
}

// ============ IP 打码 ============
function maskIP(ip) {
  if (!ip) return "N/A";
  if (ip.includes(":")) {
    // IPv6: 保留前两段
    const parts = ip.split(":");
    return parts.slice(0, 2).join(":") + ":*:*";
  }
  // IPv4: 保留前两段
  const parts = ip.split(".");
  return parts[0] + "." + parts[1] + ".*.*";
}

// ============ 风险分数显示 ============
function riskLabel(score) {
  if (score == null) return "N/A";
  return `${score}/100`;
}

// ============ HTTP 请求封装 ============
function httpGet(url, timeout) {
  return new Promise((resolve, reject) => {
    const opts = {
      url,
      timeout: timeout * 1000,
      headers: {
        "User-Agent": "Surge/IPPure-Info",
      },
    };
    $httpClient.get(opts, (err, resp, body) => {
      if (err) return reject(err);
      try {
        resolve(JSON.parse(body));
      } catch (e) {
        reject(new Error("JSON 解析失败: " + (body || "").substring(0, 100)));
      }
    });
  });
}

// ============ 主逻辑 ============
async function main() {
  const args = getArgs();

  // 事件模式：延迟执行
  if (args.type === "EVENT" && args.eventDelay > 0) {
    await new Promise((r) => setTimeout(r, args.eventDelay * 1000));
  }

  let title = "IPPure";
  let content = "";
  let icon = args.icon;
  let iconColor = args.iconColor;

  try {
    const data = await httpGet(IPPURE_API, args.timeout);

    // ---- 构建 IP 行 ----
    const ip = args.mask ? maskIP(data.ip) : data.ip;

    // ---- 构建位置行 ----
    const flag = args.flag ? countryFlag(data.countryCode) + " " : "";
    const location = [data.city, data.region, data.country]
      .filter(Boolean)
      .join(", ");
    title = `${flag}${ip}`;

    let lines = [];

    // 位置
    lines.push(`📍 ${location}`);

    // ASN & ORG
    if (args.asn || args.org) {
      let asnLine = [];
      if (args.asn && data.asn) asnLine.push(`AS${data.asn}`);
      if (args.org && data.asOrganization) asnLine.push(data.asOrganization);
      if (asnLine.length) lines.push(`🏢 ${asnLine.join(" · ")}`);
    }

    // 风险系数
    if (args.risk && data.fraudScore != null) {
      lines.push(`🛡️ 风险: ${riskLabel(data.fraudScore)}`);
    }

    // 经纬度
    if (args.geo) {
      const lat = data.latitude || "N/A";
      const lon = data.longitude || "N/A";
      lines.push(`🌐 ${lat}, ${lon}`);
    }

    // 原生 / 机房
    if (args.residential) {
      const tags = [];
      if (data.isResidential === true) {
        tags.push("🏠 原生住宅 IP");
      } else if (data.isResidential === false) {
        tags.push("🖥️ 非住宅 IP");
      }
      if (data.isBroadcast === true) {
        tags.push("📡 广播 IP");
      }
      if (tags.length) lines.push(tags.join(" | "));
    }

    content = lines.join("\n");

    // ---- 事件通知 ----
    if (args.type === "EVENT") {
      $notification.post("IPPure 网络信息", title, content);
    }
  } catch (e) {
    title = "IPPure ❌";
    content = `查询失败: ${e.message || e}`;
    if (args.type === "EVENT") {
      $notification.post("IPPure 网络信息", title, content);
    }
  }

  // ---- 面板输出 ----
  $done({
    title,
    content,
    icon,
    "icon-color": iconColor,
  });
}

main();
