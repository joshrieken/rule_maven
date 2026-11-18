// Applies the saved theme and motion choice before first paint (loaded without defer in
// the root layout's <head>). Was inline; moved out for the strict CSP.
// Map retired theme slugs to their current (kebab-of-label) names, so a
// saved theme survives a rename. Shared with the picker script. Lookup is
// one hop, so slugs from *any* past generation must point straight at a
// live slug — never at another key in this map.
window.__themeMigrate = {
  // pre-rename originals
  ocean: 'kraken', forest: 'overgrowth', retro: 'mixtape',
  scary: 'grave-digger', sunset: 'last-turn', happy: 'lemonade',
  light: 'fresh-deck', dark: 'night-owl', scifi: 'deep-space',
  matrix: 'cheat-code', fantasy: 'dungeon-master',
  // one-word era
  abyss: 'kraken', arcade: 'insert-coin', brass: 'steamworks',
  canopy: 'overgrowth', cassette: 'mixtape', coral: 'flamingo',
  crypt: 'grave-digger', dusk: 'last-turn', ember: 'campfire',
  frost: 'snow-day', 'golden-hour': 'lemonade', honey: 'honeycomb',
  lavender: 'fresh-deck', marble: 'chess-club', meadow: 'picnic',
  midnight: 'night-owl', nebula: 'deep-space', neon: 'cheat-code',
  parchment: 'dungeon-master', twilight: 'moonrise', void: 'black-hole'
};
(function() {
  var html = document.documentElement;
  var saved = localStorage.getItem('theme');
  if (saved) {
    var migrated = window.__themeMigrate[saved] || saved;
    if (migrated !== saved) localStorage.setItem('theme', migrated);
    html.setAttribute('data-theme', migrated);
  } else {
    var prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    html.setAttribute('data-theme', prefersDark ? 'night-owl' : 'fresh-deck');
  }
  // Apply the saved ambient-motion preference before paint to avoid a flash.
  if (localStorage.getItem('motion') === 'off') {
    html.setAttribute('data-motion', 'off');
  }
})();
