/// <reference path="../pb_data/types.d.ts" />
//
// Turns on PocketBase's rate limits and tells it where the visitor's address
// comes from.
//
// Rate limits: sign-in attempts and API calls are counted per visitor, with
// PocketBase's default rules (2 sign-in attempts per 3 seconds, 300 API
// requests per 10 seconds, and so on). No rules are added here; change them
// in Settings > Application in the admin panel.
//
// Visitor address: on Dockhold every request passes through Dockhold's edge,
// which sets the X-Forwarded-For header to the real client address and
// replaces whatever the client sent, so a visitor cannot forge it. With
// useLeftmostIP false PocketBase takes the rightmost value, the one the edge
// wrote. This template is tuned for Dockhold's edge. If you run the image
// behind a different proxy that does not rewrite that header, a client could
// choose its own address for rate limiting; adjust the setting there.
//
// Docs: https://pocketbase.io/docs/going-to-production/

migrate((app) => {
  const settings = app.settings();
  settings.rateLimits.enabled = true;
  settings.trustedProxy.headers = ["X-Forwarded-For"];
  settings.trustedProxy.useLeftmostIP = false;
  app.save(settings);
}, (app) => {
  const settings = app.settings();
  settings.rateLimits.enabled = false;
  settings.trustedProxy.headers = [];
  settings.trustedProxy.useLeftmostIP = false;
  app.save(settings);
});
