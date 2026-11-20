import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";

/** @type {import('next').NextConfig} */
const projectDir = process.cwd();
const isOneDriveWorkspace =
  process.platform === "win32" &&
  projectDir.split(path.sep).some((segment) => /^OneDrive(?:\s*-\s.*)?$/i.test(segment));
const outputDir = process.env.NODE_ENV === "development" ? ".next-dev" : ".next";
const distDir = isOneDriveWorkspace
  ? path.relative(
      projectDir,
      path.join(
        process.env.LOCALAPPDATA || os.tmpdir(),
        "rmmc-mi-equipment-next",
        createHash("sha256").update(projectDir.toLowerCase()).digest("hex").slice(0, 12),
        outputDir,
      ),
    )
  : outputDir;

const nextConfig = {
  distDir,
  devIndicators: false,
  poweredByHeader: false,
  productionBrowserSourceMaps: false,
  async headers() {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const supabaseOrigin = supabaseUrl ? new URL(supabaseUrl).origin : "";
    const supabaseSocketOrigin = supabaseUrl
      ? `${new URL(supabaseUrl).protocol === "https:" ? "wss:" : "ws:"}//${new URL(supabaseUrl).host}`
      : "";
    const scriptSources = ["'self'", "'unsafe-inline'"];
    if (process.env.NODE_ENV === "development") scriptSources.push("'unsafe-eval'");
    // Report-only first: Next.js injects inline bootstrap/styles, so observe violations before tightening these allowances.
    const contentSecurityPolicy = [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "form-action 'self'",
      "frame-ancestors 'none'",
      `script-src ${scriptSources.join(" ")}`,
      "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
      `img-src 'self' blob: data: ${supabaseOrigin}`,
      `connect-src 'self' ${supabaseOrigin} ${supabaseSocketOrigin}`,
      "font-src 'self' data: https://fonts.gstatic.com",
      "media-src 'self' blob:",
      "manifest-src 'self'",
      "worker-src 'self' blob:",
    ].join("; ");
    const securityHeaders = [
      { key: "Content-Security-Policy-Report-Only", value: contentSecurityPolicy },
      { key: "X-Content-Type-Options", value: "nosniff" },
      { key: "X-Frame-Options", value: "DENY" },
      { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
      { key: "Permissions-Policy", value: "camera=(self), microphone=(), geolocation=()" },
    ];

    if (process.env.NODE_ENV === "production") {
      securityHeaders.push({
        key: "Strict-Transport-Security",
        value: "max-age=31536000; includeSubDomains",
      });
    }

    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

export default nextConfig;
