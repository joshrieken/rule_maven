// The header theme picker (root layout). Was inline; moved out for the strict CSP.
(function() {
  var select = document.getElementById('theme-select');
  var html = document.documentElement;

  // True when the current page exposes a per-game palette (the Q&A/FAQ
  // pages inject `#game-theme`). Game options only appear then.
  function gameThemeAvailable() {
    return !!document.getElementById('game-theme');
  }

  // The user's static theme — the look used everywhere a game palette
  // isn't active. Never holds "game-light"/"game-dark".
  function baseTheme() {
    var s = localStorage.getItem('theme');
    if (s) {
      var migrate = window.__themeMigrate || {};
      return migrate[s] || s;
    }
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'night-owl' : 'fresh-deck';
  }

  // A game carries up to 5 generated theme sets: set 1 keeps the
  // historical game-light/game-dark slugs, sets 2+ are game-N-light/dark
  // (see RuleMaven.Metrics.game_theme_slug/2).
  function isGameTheme(v) {
    return typeof v === 'string' && /^game(-[2-5])?-(light|dark)$/.test(v);
  }

  // Broadcast the effective game-match so in-page opt-in UI (the overview
  // "Dress this page" button) can show/hide itself in sync — e.g. reappear
  // when the picker is switched back to Off.
  function announceMatch(match) {
    window.dispatchEvent(new CustomEvent('rm:gametheme', {
      detail: { match: isGameTheme(match) ? match : '0' }
    }));
  }

  // The current page's game theme variants, published with the palette
  // on the #game-theme marker as data-variants JSON:
  // [{value: "game-light", name: "Harbor Daylight"}, …] in picker order.
  // Server-side fallbacks already fill unusable names, so every entry
  // carries a label. Markers rendered before data-variants existed fall
  // back to the two legacy set-1 name attributes.
  function gameVariants() {
    var marker = document.getElementById('game-theme');
    if (!marker) return [];
    try {
      var list = JSON.parse(marker.getAttribute('data-variants') || '');
      if (Array.isArray(list)) {
        return list.filter(function(v) {
          return v && isGameTheme(v.value) && typeof v.name === 'string';
        });
      }
    } catch (_e) {}
    return [
      { value: 'game-light', name: marker.getAttribute('data-light-name') || 'Game Light' },
      { value: 'game-dark', name: marker.getAttribute('data-dark-name') || 'Game Dark' }
    ];
  }

  // Fold the game-theme options into the single site picker as two
  // pinned top optgroups — all the light looks under "Match Game Light",
  // all the dark ones under "Match Game Dark" — whenever the page offers
  // a palette. Same control on every screen size, one theme menu to learn.
  function syncGameOptions(available) {
    var schemes = ['light', 'dark'];
    var groups = {};
    schemes.forEach(function(scheme) {
      groups[scheme] = document.getElementById('theme-select-game-group-' + scheme);
    });
    if (!available) {
      schemes.forEach(function(scheme) {
        if (groups[scheme]) groups[scheme].remove();
      });
      return;
    }
    // Rebuild on EVERY sync, not just on create: the groups survive a
    // LiveView navigation from one game to the next, and both the number
    // of sets and their names differ per game. Rebuilding can reset the
    // select's value, so restore it.
    var selected = select.value;
    var variants = gameVariants();
    // Reverse creation order + insertBefore(firstChild) pins the pair as
    // [light, dark] at the TOP: buried under 20+ site themes the game
    // options were effectively invisible.
    ['dark', 'light'].forEach(function(scheme) {
      var group = groups[scheme];
      if (!group) {
        group = document.createElement('optgroup');
        group.id = 'theme-select-game-group-' + scheme;
        group.label = scheme === 'light' ? 'Match Game Light' : 'Match Game Dark';
        select.insertBefore(group, select.firstChild);
      }
      while (group.firstChild) group.removeChild(group.firstChild);
      variants.forEach(function(v) {
        if ((/dark$/.test(v.value) ? 'dark' : 'light') !== scheme) return;
        var opt = document.createElement('option');
        opt.value = v.value;
        // textContent, never innerHTML — these names are model-authored.
        opt.textContent = '🖌️ ' + v.name;
        group.appendChild(opt);
      });
    });
    select.value = selected;
  }

  // Sync the picker and active theme to the current page: the chosen game
  // variant wins on pages that offer one; otherwise the static theme.
  // Re-run after LiveView navigations because the per-game `#game-theme`
  // style block comes and goes.
  function syncTheme() {
    var base = baseTheme();
    localStorage.setItem('theme', base);
    var available = gameThemeAvailable();
    syncGameOptions(available);

    var match = localStorage.getItem('themeGameMatch');
    if (available && isGameTheme(match)) {
      // A standing selection from a game with more sets (e.g.
      // game-4-dark) may not exist on this game — fall back to set 1 of
      // the same scheme, which every game with a palette has.
      var offered = gameVariants().some(function(v) { return v.value === match; });
      if (!offered) match = /dark$/.test(match) ? 'game-dark' : 'game-light';
      html.setAttribute('data-theme', match);
      select.value = match;
    } else {
      html.setAttribute('data-theme', base);
      select.value = base;
    }
    announceMatch(match);
  }

  syncTheme();
  // LiveView swaps page content without a full reload; re-sync so leaving a
  // game page can't strand us on the now-undefined game theme.
  window.addEventListener('phx:page-loading-stop', syncTheme);
  // Regenerating a palette from the Prepare page swaps the #game-theme
  // marker (and its names) via a server push — no page-loading-stop. Pick
  // the fresh names up whenever the picker is actually opened.
  ['focus', 'pointerdown'].forEach(function(evt) {
    select.addEventListener(evt, function() {
      syncGameOptions(gameThemeAvailable());
    });
  });

  function track(value) {
    var meta = document.querySelector('meta[name="csrf-token"]');
    fetch('/theme-events', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-csrf-token': meta ? meta.getAttribute('content') : ''
      },
      body: JSON.stringify({ theme: value })
    }).catch(function() {});
  }

  // The single theme picker. On a game page its game options switch on a
  // game variant, and any other option is the explicit off-switch for that
  // variant. Off a game page there are no game options here, so a standing
  // game selection is preserved and wins again on return to that game.
  select.addEventListener('change', function() {
    if (isGameTheme(this.value)) {
      localStorage.setItem('themeGameMatch', this.value);
      html.setAttribute('data-theme', this.value);
      announceMatch(this.value);
      track(this.value);
      return;
    }
    localStorage.setItem('theme', this.value);
    if (gameThemeAvailable()) {
      localStorage.setItem('themeGameMatch', '0');
      announceMatch('0');
    }
    html.setAttribute('data-theme', this.value);
    track(this.value);
  });

  // ‹ / › step the picker one option at a time, wrapping at the ends and
  // skipping the optgroup labels (they aren't <option>s) — a theme can be
  // cycled without opening the native dropdown, which is the fiddly part on
  // touch. Refresh the game options first so a game page's variants are in
  // the list, then reuse the change path so tracking + localStorage + the
  // game-match announce all fire exactly as a manual pick would.
  function stepTheme(dir) {
    syncGameOptions(gameThemeAvailable());
    var opts = Array.prototype.filter.call(select.options, function(o) {
      return !o.disabled;
    });
    if (!opts.length) return;
    var current = select.options[select.selectedIndex];
    var idx = opts.indexOf(current);
    if (idx < 0) idx = 0;
    idx = (idx + dir + opts.length) % opts.length;
    select.value = opts[idx].value;
    select.dispatchEvent(new Event('change'));
  }
  var prevBtn = document.getElementById('theme-prev');
  var nextBtn = document.getElementById('theme-next');
  if (prevBtn) prevBtn.addEventListener('click', function() { stepTheme(-1); });
  if (nextBtn) nextBtn.addEventListener('click', function() { stepTheme(1); });

  // Ambient-animation toggle.
  var motionBtn = document.getElementById('motion-toggle');
  if (motionBtn) {
    function syncMotion() {
      var off = localStorage.getItem('motion') === 'off';
      html.setAttribute('data-motion', off ? 'off' : 'on');
      motionBtn.setAttribute('aria-pressed', off ? 'true' : 'false');
    }
    syncMotion();
    motionBtn.addEventListener('click', function() {
      var off = localStorage.getItem('motion') === 'off';
      localStorage.setItem('motion', off ? 'on' : 'off');
      syncMotion();
    });
  }
})();
