/**
 * Cloudflare Pages Function: /dl/exe and /dl/zip
 *
 * Tracked toolkit download links. Each hit emails Eric who downloaded
 * (time, city/region/country, ISP, device, IP) via Resend, then 302s the
 * browser to the GitHub Release asset. The email is sent in the background
 * (waitUntil), so the download never waits on it, and an email failure
 * never blocks a download.
 *
 *   /dl/exe            -> releases/latest/download/iDezign-Toolkit.exe
 *   /dl/exe?v=3.7      -> releases/download/v3.7/iDezign-Toolkit.exe
 *   /dl/zip[?v=...]    -> same for the .zip
 *
 * Uses the existing RESEND_API_KEY env var (same as /api/help-intake).
 */

const REPO = 'https://github.com/idezigntech/idezign-site/releases';
const FILES = { exe: 'iDezign-Toolkit.exe', zip: 'iDezign-Toolkit.zip' };
const BOT_RE = /bot|crawl|spider|slurp|scan|preview|monitor|curl|wget|python|go-http|headless|virustotal|defender|safebrowsing/i;

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[c]));
}

function row(label, value) {
  return `<tr><td style="padding:6px 20px 6px 0;color:#6a6a6a;white-space:nowrap;vertical-align:top">${esc(label)}</td><td style="padding:6px 0">${esc(value) || '&mdash;'}</td></tr>`;
}

async function notify(env, info) {
  if (!env.RESEND_API_KEY) return;
  const where = [info.city, info.region, info.country].filter(Boolean).join(', ');
  const tag = info.likelyBot ? ' [likely bot/scanner]' : '';
  const html = `
    <div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-weight:300;color:#161616;max-width:540px">
      <h2 style="color:#A82828;font-weight:500;font-size:20px;margin:0 0 18px">Toolkit download: ${esc(info.file)}${esc(tag)}</h2>
      <table style="border-collapse:collapse;font-size:14px">
        ${row('Time', info.time)}
        ${row('Version', info.version || 'latest')}
        ${row('Location', where)}
        ${row('Network', info.isp)}
        ${row('IP', info.ip)}
        ${row('Device', info.ua)}
        ${row('Came from', info.referer)}
      </table>
    </div>`;
  await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'iDezign Downloads <noreply@idezign.ai>',
      to: ['eric@idezign.com'],
      subject: `Toolkit download - ${where || info.ip}${tag}`,
      html,
    }),
  });
}

export async function onRequestGet(context) {
  const { request, params, env } = context;
  const asset = String(params.asset || '').toLowerCase();
  const file = FILES[asset];
  if (!file) return new Response('Not found', { status: 404 });

  const url = new URL(request.url);
  const v = (url.searchParams.get('v') || '').trim();
  const version = /^[0-9]+(\.[0-9]+){0,3}$/.test(v) ? v : '';
  const target = version ? `${REPO}/download/v${version}/${file}` : `${REPO}/latest/download/${file}`;

  const cf = request.cf || {};
  const ua = request.headers.get('User-Agent') || '';
  const info = {
    file,
    version,
    time: new Date().toLocaleString('en-US', { timeZone: 'America/Los_Angeles', dateStyle: 'medium', timeStyle: 'short' }),
    city: cf.city, region: cf.region, country: cf.country,
    isp: cf.asOrganization,
    ip: request.headers.get('CF-Connecting-IP') || '',
    ua,
    referer: request.headers.get('Referer') || '',
    likelyBot: !ua || BOT_RE.test(ua),
  };
  context.waitUntil(notify(env, info).catch(() => {}));

  return new Response(null, {
    status: 302,
    headers: { Location: target, 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex' },
  });
}
