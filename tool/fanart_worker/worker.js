// Konata Fanart.tv v3 无状态边缘中继（Cloudflare Workers 免费版兼容）。
//
// 防护与缓存架构：
// 1. Zone 层（零 Worker 额度消耗）：免费 WAF 拦截非 GET、非空 Query 与非白名单路径；免费 Rate Limiting 拦截 10s 洪水；
// 2. Worker 层：[[ratelimits]] 按 IP 60s 窗限流 + 严格路径/ID 归一化 + 硬编码上游主机（严禁代理任何图片域名）；
// 3. 双层缓存：匿名默认请求先查 L1（本 Colo 裁剪后 JSON），未命中再经 L2 fetch(cf.cacheTtlByStatus) 命中免费版 Smart Tiered Cache；
//    携带合法个人 client-key 的请求完全绕过共享缓存直通上游，返回 private, no-store，杜绝互相污染。

const ALLOWED_PATH = /^\/fanart\/v3\/(tv|movies)\/([1-9]\d{0,8})$/;
const CLIENT_KEY_PATTERN = /^[A-Za-z0-9]{16,64}$/;
const UPSTREAM_ORIGIN = 'https://webservice.fanart.tv';
const POSITIVE_TTL_SECONDS = 43200; // 12 小时正缓存
const NEGATIVE_TTL_SECONDS = 7200; // 2 小时 404 负缓存
const ARTWORK_FIELDS = [
  'name',
  'tmdb_id',
  'thetvdb_id',
  'hdtvlogo',
  'clearlogo',
  'hdmovielogo',
  'movielogo',
  'tvposter',
  'seasonposter',
  'movieposter',
  'showbackground',
  'moviebackground',
];

function jsonResponse(payload, status, extraHeaders = {}) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
      ...extraHeaders,
    },
  });
}

function slimArtworkPayload(raw) {
  if (!raw || typeof raw !== 'object') return {};
  const slim = {};
  for (const key of ARTWORK_FIELDS) {
    if (key in raw) {
      slim[key] = raw[key];
    }
  }
  return slim;
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'GET') {
      return jsonResponse({ error: 'method_not_allowed' }, 405, {
        Allow: 'GET',
        'Cache-Control': 'no-store',
      });
    }

    const url = new URL(request.url);
    if (url.search.length > 0) {
      return jsonResponse({ error: 'query_not_allowed' }, 400, {
        'Cache-Control': 'no-store',
      });
    }

    const matched = ALLOWED_PATH.exec(url.pathname);
    if (!matched) {
      return jsonResponse({ error: 'not_found' }, 404, {
        'Cache-Control': 'no-store',
      });
    }

    const mediaType = matched[1];
    const numericId = matched[2];

    const rawClientKey = (request.headers.get('client-key') || '').trim();
    const hasClientKey = rawClientKey.length > 0;
    if (hasClientKey && !CLIENT_KEY_PATTERN.test(rawClientKey)) {
      return jsonResponse({ error: 'invalid_client_key' }, 400, {
        'Cache-Control': 'no-store',
      });
    }

    // Worker 层分钟级按 IP 限流（基于 Cloudflare 免费 [[ratelimits]] Binding）
    const clientIp = (request.headers.get('cf-connecting-ip') || 'unknown').trim();
    const limiter = hasClientKey
      ? env.FANART_PERSONAL_LIMITER
      : env.FANART_ANON_LIMITER;
    if (limiter && typeof limiter.limit === 'function') {
      const rateKey = `${hasClientKey ? 'personal' : 'anon'}:${clientIp}`;
      const outcome = await limiter.limit({ key: rateKey });
      if (!outcome.success) {
        return jsonResponse({ error: 'rate_limited', retryAfter: 60 }, 429, {
          'Retry-After': '60',
          'X-Konata-Relay-Error': 'rate_limited',
          'Cache-Control': 'no-store',
        });
      }
    }

    const projectKey = (env.FANART_PROJECT_KEY || '').trim();
    if (!projectKey) {
      return jsonResponse({ error: 'relay_not_configured' }, 503, {
        'X-Konata-Relay-Error': 'relay_not_configured',
        'Cache-Control': 'no-store',
      });
    }

    // 统一归一化键（绝不引用原始 request.url，杜绝大小写与多余斜杠导致的缓存分裂）
    const l1CacheKey = new Request(
      `https://konata-fanart-art.internal/v3/${mediaType}/${numericId}`,
      { method: 'GET' },
    );
    const upstreamUrl = `${UPSTREAM_ORIGIN}/v3/${mediaType}/${numericId}`;

    // L1：仅匿名默认通道读取本节点裁剪后极简 JSON 缓存
    if (!hasClientKey) {
      const cached = await caches.default.match(l1CacheKey);
      if (cached) {
        return cached;
      }
    }

    const upstreamHeaders = {
      Accept: 'application/json',
      'User-Agent': 'Konata-Fanart-Relay/2.0',
      'api-key': projectKey,
    };
    if (hasClientKey) {
      upstreamHeaders['client-key'] = rawClientKey;
      upstreamHeaders['Cache-Control'] = 'no-cache';
    }

    // L2：匿名通道走免费版 Smart Tiered Cache 跨 Colo 共享缓存；个人 Key 强制绕过缓存直通上游
    const fetchInit = hasClientKey
      ? {
          method: 'GET',
          headers: upstreamHeaders,
          cf: {
            cacheEverything: false,
            cacheTtl: 0,
          },
        }
      : {
          method: 'GET',
          headers: upstreamHeaders,
          cf: {
            cacheEverything: true,
            cacheTtlByStatus: {
              '200-299': POSITIVE_TTL_SECONDS,
              404: NEGATIVE_TTL_SECONDS,
              '500-599': 0,
            },
          },
        };

    let upstreamResp;
    try {
      upstreamResp = await fetch(upstreamUrl, fetchInit);
    } catch (_) {
      return jsonResponse({ error: 'upstream_unreachable' }, 502, {
        'Cache-Control': 'no-store',
      });
    }

    if (upstreamResp.status === 404) {
      const notFoundResp = jsonResponse({ error: 'not_found' }, 404, {
        'Cache-Control': hasClientKey
          ? 'private, no-store'
          : `public, max-age=${NEGATIVE_TTL_SECONDS}`,
        Vary: 'client-key',
      });
      if (!hasClientKey) {
        ctx.waitUntil(caches.default.put(l1CacheKey, notFoundResp.clone()));
      }
      return notFoundResp;
    }

    if (upstreamResp.status === 429) {
      const retryAfter = upstreamResp.headers.get('retry-after') || '60';
      return jsonResponse({ error: 'upstream_rate_limited' }, 429, {
        'Retry-After': retryAfter,
        'X-Konata-Relay-Error': 'rate_limited',
        'Cache-Control': 'no-store',
      });
    }

    if (upstreamResp.status === 401 || upstreamResp.status === 403) {
      return jsonResponse({ error: 'upstream_rejected' }, upstreamResp.status, {
        'X-Konata-Relay-Error': hasClientKey
          ? 'client_key_invalid'
          : 'project_key_rejected',
        'Cache-Control': 'no-store',
      });
    }

    if (!upstreamResp.ok) {
      return jsonResponse({ error: 'upstream_error' }, 502, {
        'Cache-Control': 'no-store',
      });
    }

    let parsed;
    try {
      parsed = await upstreamResp.json();
    } catch (_) {
      return jsonResponse({ error: 'invalid_upstream_json' }, 502, {
        'Cache-Control': 'no-store',
      });
    }

    const response = jsonResponse(slimArtworkPayload(parsed), 200, {
      'Cache-Control': hasClientKey
        ? 'private, no-store'
        : `public, max-age=${POSITIVE_TTL_SECONDS}`,
      Vary: 'client-key',
    });

    if (!hasClientKey) {
      ctx.waitUntil(caches.default.put(l1CacheKey, response.clone()));
    }
    return response;
  },
};
