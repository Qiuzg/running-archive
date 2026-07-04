const AMAP_PROXY_TARGETS = [
  {
    prefix: "v4/map/styles",
    target: "https://webapi.amap.com/v4/map/styles",
  },
  {
    prefix: "v3/vectormap",
    target: "https://fmap01.amap.com/v3/vectormap",
  },
];

function getPath(params) {
  const value = params?.path;
  if (Array.isArray(value)) return value.join("/");
  return value || "";
}

function isSameHostUrl(value, host) {
  if (!value) return true;
  try {
    return new URL(value).hostname === host;
  } catch (_) {
    return false;
  }
}

function buildAmapUrl(requestUrl, path, jscode) {
  const sourceUrl = new URL(requestUrl);
  const matched = AMAP_PROXY_TARGETS.find((item) => path === item.prefix || path.startsWith(`${item.prefix}/`));
  const suffix = matched ? path.slice(matched.prefix.length) : path;
  const base = matched ? matched.target : "https://restapi.amap.com";
  const targetUrl = new URL(`${base}${suffix ? `/${suffix.replace(/^\/+/, "")}` : ""}`);
  targetUrl.search = sourceUrl.search;
  targetUrl.searchParams.set("jscode", jscode);
  return targetUrl;
}

export async function onRequest(context) {
  const { request, env, params } = context;
  if (request.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Allow-Methods": "GET,HEAD,POST,OPTIONS",
        "Access-Control-Allow-Origin": new URL(request.url).origin,
      },
    });
  }

  const jscode = env.AMAP_SECURITY_JSCODE;
  if (!jscode) {
    return new Response("Missing AMAP_SECURITY_JSCODE", { status: 500 });
  }

  const host = new URL(request.url).hostname;
  const origin = request.headers.get("Origin");
  const referer = request.headers.get("Referer");
  if (!isSameHostUrl(origin, host) || !isSameHostUrl(referer, host)) {
    return new Response("Forbidden", { status: 403 });
  }

  const headers = new Headers(request.headers);
  headers.delete("host");
  headers.delete("referer");
  headers.delete("origin");

  const targetUrl = buildAmapUrl(request.url, getPath(params), jscode);
  const upstream = await fetch(targetUrl, {
    body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
    headers,
    method: request.method,
    redirect: "follow",
  });

  const responseHeaders = new Headers(upstream.headers);
  responseHeaders.set("Access-Control-Allow-Origin", new URL(request.url).origin);
  responseHeaders.set("Vary", "Origin");
  return new Response(upstream.body, {
    headers: responseHeaders,
    status: upstream.status,
    statusText: upstream.statusText,
  });
}
