## Surge HTTP Request Hook: 自动填充登录请求
let url = $request.url;
let headers = $request.headers;
let body = $request.body;

## 目标网站的登录 API
if (url.includes("transmedlims.pumch.cn/Account/login")) {
    let newBody = "userName=S2024001046&password=Wwb@13306120968"; // 替换为你的账户信息
    let newHeaders = {
        ...headers,
        "Content-Type": "application/x-www-form-urlencoded"
    };

    console.log("🔹 自动填充用户名 & 密码成功！");
    
    $done({ body: newBody, headers: newHeaders });
} else {
    $done({});
}
