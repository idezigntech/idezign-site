/**
 * Cloudflare Pages Function: /api/help-intake
 *
 * Handles POST submissions from idezign.ai/help. Generates a short session code,
 * emails Eric via Resend, and returns the code to the page.
 *
 * Required env var (set in Cloudflare Pages dashboard):
 *   RESEND_API_KEY — Resend API key with sending access for idezign.ai
 *
 * Expected POST body (application/json):
 *   { name, company?, contact, issue, skipped? }
 *   OR
 *   { skipped: true }
 *
 * Response (200):
 *   { success: true, sessionCode: "iDH-XXXX" }
 *
 * Response (500):
 *   { success: false, error: "..." }
 */

// Alphabet excludes ambiguous chars when read verbally: 0, O, 1, I, L
const SAFE_CHARS = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function generateSessionCode() {
  const buf = new Uint32Array(4);
  crypto.getRandomValues(buf);
  let code = 'iDH-';
  for (let i = 0; i < 4; i++) {
    code += SAFE_CHARS[buf[i] % SAFE_CHARS.length];
  }
  return code;
}

function escapeHtml(input) {
  if (input === null || input === undefined) return '';
  return String(input)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function formatPST(date) {
  return date.toLocaleString('en-US', {
    timeZone: 'America/Los_Angeles',
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    timeZoneName: 'short',
  });
}

function buildPhoneInEmail(sessionCode, timestamp) {
  return {
    subject: `Phone-in support request — ${sessionCode}`,
    html: `
      <div style="font-family: 'Jost', -apple-system, BlinkMacSystemFont, sans-serif; font-weight: 300; color: #161616; max-width: 520px;">
        <h2 style="color: #A82828; font-weight: 500; font-size: 22px; letter-spacing: -0.01em; margin: 0 0 12px;">Phone-in support request</h2>
        <p style="color: #6a6a6a; font-size: 14px; margin: 0 0 24px;">Client skipped the intake form &mdash; likely on the phone with you already.</p>
        <table style="border-collapse: collapse; font-size: 15px;">
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a;">Code</td>
            <td style="padding: 8px 0; font-weight: 500; font-family: monospace;">${escapeHtml(sessionCode)}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a;">Time</td>
            <td style="padding: 8px 0;">${escapeHtml(timestamp)}</td>
          </tr>
        </table>
        <hr style="border: none; border-top: 1px solid #ececec; margin: 28px 0 16px;">
        <p style="color: #6a6a6a; font-size: 13px; margin: 0;">&rarr; Watch for incoming TeamViewer connection.</p>
      </div>
    `,
  };
}

function buildFullIntakeEmail(data, sessionCode, timestamp) {
  const name = escapeHtml(data.name);
  const company = data.company ? escapeHtml(data.company) : '&mdash;';
  const contact = escapeHtml(data.contact);
  const issue = escapeHtml(data.issue).replace(/\n/g, '<br>');
  const companyInSubject = data.company ? ` (${escapeHtml(data.company)})` : '';

  return {
    subject: `iDezign Help Session — ${name}${companyInSubject}`,
    html: `
      <div style="font-family: 'Jost', -apple-system, BlinkMacSystemFont, sans-serif; font-weight: 300; color: #161616; max-width: 540px;">
        <h2 style="color: #A82828; font-weight: 500; font-size: 22px; letter-spacing: -0.01em; margin: 0 0 24px;">New iDezign Help Session</h2>
        <table style="border-collapse: collapse; font-size: 15px;">
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Code</td>
            <td style="padding: 8px 0; font-weight: 500; font-family: monospace;">${escapeHtml(sessionCode)}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Name</td>
            <td style="padding: 8px 0;">${name}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Company</td>
            <td style="padding: 8px 0;">${company}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Contact</td>
            <td style="padding: 8px 0;">${contact}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Issue</td>
            <td style="padding: 8px 0; line-height: 1.5;">${issue}</td>
          </tr>
          <tr>
            <td style="padding: 8px 24px 8px 0; color: #6a6a6a; vertical-align: top; white-space: nowrap;">Time</td>
            <td style="padding: 8px 0;">${escapeHtml(timestamp)}</td>
          </tr>
        </table>
        <hr style="border: none; border-top: 1px solid #ececec; margin: 28px 0 16px;">
        <p style="color: #6a6a6a; font-size: 13px; margin: 0;">&rarr; They&rsquo;re likely about to download QuickSupport. Watch for incoming TeamViewer.</p>
      </div>
    `,
  };
}

async function sendEmail(env, payload) {
  return fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: 'iDezign Help <noreply@idezign.ai>',
      to: ['eric@idezign.com'],
      subject: payload.subject,
      html: payload.html,
    }),
  });
}

export async function onRequestPost({ request, env }) {
  // Guard: missing API key would silently fail email; surface the error during dev
  if (!env.RESEND_API_KEY) {
    return new Response(
      JSON.stringify({ success: false, error: 'Email service not configured.' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }

  let body;
  try {
    body = await request.json();
  } catch (e) {
    return new Response(
      JSON.stringify({ success: false, error: 'Invalid request body.' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    );
  }

  const sessionCode = generateSessionCode();
  const timestamp = formatPST(new Date());
  const isPhoneIn = body.skipped === true;

  // Validate full intake submissions
  if (!isPhoneIn) {
    const name = (body.name || '').trim();
    const contact = (body.contact || '').trim();
    const issue = (body.issue || '').trim();
    if (!name || !contact || !issue) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'Name, contact, and what’s going on are all required.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      );
    }
    body.name = name;
    body.contact = contact;
    body.issue = issue;
    if (body.company) body.company = body.company.trim();
  }

  const email = isPhoneIn
    ? buildPhoneInEmail(sessionCode, timestamp)
    : buildFullIntakeEmail(body, sessionCode, timestamp);

  try {
    const resendRes = await sendEmail(env, email);
    if (!resendRes.ok) {
      const errText = await resendRes.text();
      console.error('Resend error', resendRes.status, errText);
      // Still return success with the code — don't block the client because email failed.
      // Eric will see the user come through TeamViewer either way.
    }
  } catch (err) {
    console.error('Resend fetch threw', err);
    // Same approach — email failure shouldn't break the flow.
  }

  return new Response(
    JSON.stringify({ success: true, sessionCode }),
    { headers: { 'Content-Type': 'application/json' } }
  );
}

// Allow CORS preflights if you ever post from a different domain (defensive).
export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': 'https://idezign.ai',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Max-Age': '86400',
    },
  });
}
