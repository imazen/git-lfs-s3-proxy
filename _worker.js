import { AwsClient } from "aws4fetch";

const HOMEPAGE = "https://github.com/milkey-mouse/git-lfs-s3-proxy";
const EXPIRY = 3600;

const MIME = "application/vnd.git-lfs+json";

const METHOD_FOR = {
  upload: "PUT",
  download: "GET",
};

async function sign(s3, bucket, path, method) {
  const info = { method };
  const signed = await s3.sign(
    new Request(`https://${bucket}/${path}?X-Amz-Expires=${EXPIRY}`, info),
    { aws: { signQuery: true } },
  );
  return signed.url;
}

function parseAuthorization(req) {
  const auth = req.headers.get("Authorization");
  if (!auth) {
    throw new Response(null, { status: 401 });
  }

  const [scheme, encoded] = auth.split(" ");
  if (scheme !== "Basic" || !encoded) {
    throw new Response(null, { status: 400 });
  }

  const buffer = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
  const decoded = new TextDecoder().decode(buffer);
  const index = decoded.indexOf(":");
  if (index === -1) {
    throw new Response(null, { status: 400 });
  }

  return { user: decoded.slice(0, index), pass: decoded.slice(index + 1) };
}

// PUBLIC_DOWNLOAD_BASES: {"<endpoint>/<bucket>[/<prefix>]": "https://public.example"}
// — an object (or JSON string) mapping the location segment of the LFS URL to
// the public base URL that serves the same objects. Longest match wins; the
// remainder of the location is appended to the base.
function publicBaseFor(env, bucket) {
  let bases = env.PUBLIC_DOWNLOAD_BASES;
  if (!bases) {
    return null;
  }
  if (typeof bases === "string") {
    bases = JSON.parse(bases);
  }
  let best = null;
  for (const [loc, base] of Object.entries(bases)) {
    if (bucket === loc || bucket.startsWith(loc + "/")) {
      if (best === null || loc.length > best.length) {
        best = loc;
      }
    }
  }
  if (best === null) {
    return null;
  }
  return bases[best].replace(/\/+$/, "") + bucket.slice(best.length);
}

async function fetch(req, env) {
  try {
    return await handle(req, env);
  } catch (e) {
    // parseAuthorization throws a Response to short-circuit; hand it back.
    if (e instanceof Response) {
      return e;
    }
    throw e;
  }
}

async function handle(req, env) {
  const url = new URL(req.url);

  if (url.pathname == "/") {
    if (req.method === "GET") {
      return Response.redirect(HOMEPAGE, 302);
    } else {
      return new Response(null, { status: 405, headers: { Allow: "GET" } });
    }
  }

  if (!url.pathname.endsWith("/objects/batch")) {
    return new Response(null, { status: 404 });
  }

  if (req.method !== "POST") {
    return new Response(null, { status: 405, headers: { Allow: "POST" } });
  }

  // in practice, we'd rather not break out-of-spec clients not setting these
  /*if (!req.headers.get("Accept").startsWith(MIME)
    || !req.headers.get("Content-Type").startsWith(MIME)) {
    return new Response(null, { status: 406 });
  }*/

  let s3Options = {};

  const segments = url.pathname.split("/").slice(1, -2);
  let params = {};
  let bucketIdx = 0;
  for (const segment of segments) {
    const sliceIdx = segment.indexOf("=");
    if (sliceIdx === -1) {
      break;
    } else {
      const key = decodeURIComponent(segment.slice(0, sliceIdx));
      const val = decodeURIComponent(segment.slice(sliceIdx + 1));
      s3Options[key] = val;

      bucketIdx++;
    }
  }

  const bucket = segments.slice(bucketIdx).join("/");

  // Optional hardening for a self-hosted instance: only sign URLs for the S3
  // endpoints listed in ALLOWED_ENDPOINTS (comma-separated hostnames, or
  // parent domains that match as a suffix). Unset means "any", like upstream.
  const allowed = (env.ALLOWED_ENDPOINTS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const endpointHost = bucket.split("/")[0];
  if (
    allowed.length &&
    !allowed.some((a) => endpointHost === a || endpointHost.endsWith("." + a))
  ) {
    return new Response(null, { status: 403 });
  }
  const expires_in = params.expiry || env.EXPIRY || EXPIRY;

  const { objects, operation, hash_algo = "sha256" } = await req.json();

  if (hash_algo !== "sha256") {
    return new Response(
      JSON.stringify({
        message: `Hash algorithm '${hash_algo}' is not supported. Only 'sha256' is currently supported.`,
      }),
      {
        status: 409,
        headers: { "Content-Type": "application/vnd.git-lfs+json" },
      },
    );
  }

  const method = METHOD_FOR[operation];
  if (!method) {
    return new Response(
      JSON.stringify({ message: `Unsupported operation '${operation}'.` }),
      { status: 422, headers: { "Content-Type": MIME } },
    );
  }

  // Downloads from a publicly readable bucket need no credentials at all: when
  // the request carries no Authorization header and PUBLIC_DOWNLOAD_BASES maps
  // this location to a public base URL, hand out plain URLs instead of signed
  // ones. Uploads, and any request that does present credentials, take the
  // signed path exactly as upstream.
  const publicBase =
    operation === "download" && !req.headers.get("Authorization")
      ? publicBaseFor(env, bucket)
      : null;

  let action;
  if (publicBase) {
    action = async (oid) => ({ href: `${publicBase}/${oid}` });
  } else {
    const { user, pass } = parseAuthorization(req);
    const s3 = new AwsClient({
      accessKeyId: user,
      secretAccessKey: pass,
      ...s3Options,
    });
    action = async (oid) => ({
      href: await sign(s3, bucket, oid, method),
      expires_in,
    });
  }

  const response = JSON.stringify({
    transfer: "basic",
    hash_algo: "sha256",
    objects: await Promise.all(
      objects.map(async ({ oid, size }) => ({
        oid,
        size,
        authenticated: true,
        actions: { [operation]: await action(oid) },
      })),
    ),
  });

  return new Response(response, {
    status: 200,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/vnd.git-lfs+json",
    },
  });
}

export default { fetch };
