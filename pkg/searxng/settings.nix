{
  use_default_settings = true;
  # Allow GET so `?q=...&format=json` works for API clients.
  server.method = "GET";
  # Enable the JSON API (default is HTML-only).
  search.formats = [ "html" "json" ];
  # Brave autocomplete on by default.
  search.autocomplete = "brave";
  default_doi_resolver = "sci-hub.st";
  # Favicon resolver on by default (resolved via DuckDuckGo). Setting a
  # default also populates the resolver choice in the preferences page.
  search.favicon_resolver = "duckduckgo";
  # Engines are merged by name over the package defaults, so these entries
  # only flip `disabled` and leave the rest intact. bing/qwant/yahoo ship
  # disabled upstream; google/duckduckgo/brave are listed for explicitness/
  # idempotency. `yandex images` enables Yandex for images.
  engines = [
    { name = "bing"; disabled = false; }
    { name = "brave"; disabled = false; }
    { name = "duckduckgo"; disabled = false; }
    { name = "google"; disabled = false; }
    { name = "yahoo"; disabled = false; }
    { name = "yandex images"; disabled = false; }
    { name = "crowdview"; disabled = false; }
    { name = "fynd"; disabled = false; }
    { name = "gmx"; disabled = false; }
    { name = "zapmeta"; disabled = false; }
    { name = "ddg definitions"; disabled = false; }

    { name = "resulthunter"; disabled = true; }
    { name = "yep"; disabled = true; }
    { name = "privacywall"; disabled = true; }
    { name = "yacy"; disabled = true; }
    { name = "fastbot"; disabled = true; }
    { name = "fireball"; disabled = true; }
    { name = "qwant"; disabled = true; }
    { name = "wikidata"; disabled = true; }
  ];
}
