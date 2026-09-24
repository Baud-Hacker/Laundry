# Strong anti-cache for gated responses: no intermediary (browser, proxy, CDN)
# may store, reuse, or revalidate hidden content for another client.
more_set_headers 'Cache-Control: no-store, no-cache, must-revalidate, private, max-age=0';
more_set_headers 'Pragma: no-cache';
more_set_headers 'Expires: 0';
more_set_headers 'Surrogate-Control: no-store';
# Strip validators so no conditional revalidation can leak existence/content.
more_clear_headers 'ETag';
more_clear_headers 'Last-Modified';
