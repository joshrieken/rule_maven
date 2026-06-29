let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

// Fun thank-you toast when a user up-votes an answer. The server pushes a
// "vote_thanks" event, which LiveView re-dispatches on window as phx:vote_thanks.
const VOTE_THANKS = [
  ["🎉", "You're a legend! Thanks!"],
  ["🙌", "Knowledge leveled up!"],
  ["🚀", "Answer boosted!"],
  ["🦸", "You made this better!"],
  ["✨", "High five! Much appreciated."],
  ["🎲", "Thanks, you rule!"],
  ["🌟", "Gold star for you!"],
];
function showToast(emoji, msg) {
  document.querySelectorAll(".vote-toast").forEach((t) => t.remove());
  const toast = document.createElement("div");
  toast.className = "vote-toast";
  const e = document.createElement("span");
  e.className = "vote-toast__emoji";
  e.textContent = emoji;
  const t = document.createElement("span");
  t.textContent = msg;
  toast.appendChild(e);
  toast.appendChild(t);
  document.body.appendChild(toast);
  setTimeout(() => toast.remove(), 2700);
}
function showVoteThanks() {
  const [emoji, msg] = VOTE_THANKS[Math.floor(Math.random() * VOTE_THANKS.length)];
  showToast(emoji, msg);
}
window.addEventListener("phx:vote_thanks", showVoteThanks);

// Make open <details class="card-menu"> dropdowns behave like a modal: a click
// anywhere outside the open menu closes it and is swallowed (it does NOT also
// activate whatever is underneath), so the next click interacts normally.
//
// A full-screen backdrop element can't work here because the menu lives inside
// .chat-messages (z-index:1), a stacking context the popup can't escape — a
// body-level backdrop would always paint over it. Instead we swallow the
// outside click directly in the capture phase, before it reaches its target or
// LiveView's delegated handler.
(function () {
  let owner = null;

  function insideOpenMenu(target) {
    if (!owner) return false;
    const pop = owner.querySelector(".card-menu__pop");
    const sum = owner.querySelector("summary");
    return (pop && pop.contains(target)) || (sum && sum.contains(target));
  }

  function swallowOutside(e) {
    if (!owner || insideOpenMenu(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.stopImmediatePropagation) e.stopImmediatePropagation();
    owner.open = false; // fires toggle -> owner = null
  }
  // Capture on window: runs before the target and before LiveView's listeners.
  window.addEventListener("click", swallowOutside, true);

  // toggle doesn't bubble; capture phase still reaches a document listener.
  document.addEventListener(
    "toggle",
    (e) => {
      const det = e.target;
      if (!(det instanceof HTMLDetailsElement) || !det.classList.contains("card-menu")) {
        return;
      }
      if (det.open) {
        document.querySelectorAll("details.card-menu[open]").forEach((d) => {
          if (d !== det) d.open = false;
        });
        owner = det;
      } else if (owner === det) {
        owner = null;
      }
    },
    true
  );
})();

let Hooks = {};
// Persists the selected game-list view to localStorage when the server
// pushes "save_view". Restored on connect via the LiveSocket params above.
Hooks.ViewPref = {
  mounted() {
    this.handleEvent("save_view", ({view}) => {
      localStorage.setItem("rm:gamelist:view", view);
    });
    // Remember how many rows were loaded so the list can be restored to the
    // same depth (and scroll offset) when the user comes back to it.
    this.handleEvent("save_count", ({count}) => {
      localStorage.setItem("rm:gamelist:count", count);
    });
    // Search/filter/view changes reset the list, so the saved spot is stale.
    this.handleEvent("reset_list_pos", () => {
      localStorage.removeItem("rm:gamelist:count");
      localStorage.removeItem("rm:gamelist:scroll");
    });
  }
};
Hooks.FlashAutoHide = {
  mounted() {
    let duration = parseInt(this.el.dataset.flashDuration) || 4000;
    this._hide = () => {
      this.el.style.transition = "opacity 300ms ease-out";
      this.el.style.opacity = "0";
      setTimeout(() => { this.el.remove(); }, 300);
    };
    this._timer = setTimeout(this._hide, duration);
  },
  updated() {
    clearTimeout(this._timer);
    this.el.style.opacity = "1";
    let duration = parseInt(this.el.dataset.flashDuration) || 4000;
    this._timer = setTimeout(this._hide, duration);
  },
  destroyed() {
    clearTimeout(this._timer);
  }
};

Hooks.ExternalLink = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      window.open(this.el.href, "_blank", "noopener");
    });
  }
};

Hooks.ChatScroll = {
  mounted() {
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    // Don't auto-scroll on page load — leave the view at the top. Scrolling only
    // happens on later updates (a new answer arriving) and the scroll_bottom event.
    this.answerCount = this.countAnswers();
    this.handleEvent("scroll_bottom", () => this.scrollToBottom());
    // Server fires this when a finished answer arrives — jump to its top so the
    // reader starts at the beginning of the answer.
    this.handleEvent("scroll_answer_top", () => this.scrollToLatestAnswer());
  },
  updated() {
    // updated() fires on every LiveView patch — voting, toggling the sidebar,
    // etc. — not just when a new answer arrives. Only scroll when the number of
    // assistant messages actually grew, otherwise unrelated interactions yank
    // the page around.
    const count = this.countAnswers();
    if (count > this.answerCount) {
      this.scrollToLatestAnswer();
    }
    this.answerCount = count;
  },
  destroyed() {
    document.documentElement.style.overflow = "";
    document.body.style.overflow = "";
  },
  countAnswers() {
    return this.el.querySelectorAll(".chat-msg:not(.chat-msg-user)").length;
  },
  scrollToLatestAnswer() {
    const el = this.el;
    requestAnimationFrame(() => {
      // Find the last assistant message and scroll it to the top of the viewport
      const messages = el.querySelectorAll(".chat-msg:not(.chat-msg-user)");
      const last = messages[messages.length - 1];
      if (last) {
        last.scrollIntoView({ behavior: "smooth", block: "start" });
      }
    });
  },
  scrollToBottom() {
    const el = this.el;
    requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
  }
};

Hooks.FocusInput = {
  mounted() {
    requestAnimationFrame(() => this.el.focus({ preventScroll: true }));
  }
};

Hooks.KeyboardSubmit = {
  mounted() {
    this._handler = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        this.el.dispatchEvent(new Event("submit", { bubbles: true }));
      }
    };
    this.el.addEventListener("keydown", this._handler);
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._handler);
  }
};

Hooks.Refocus = {
  mounted() {
    // Restore saved search from localStorage
    const saved = localStorage.getItem("game-search") || "";
    this.el.value = saved;
    this.pushEvent("restore_search", { value: saved });
    this.el.focus();
    // Save on each input change
    this._saveHandler = () => {
      localStorage.setItem("game-search", this.el.value);
    };
    this.el.addEventListener("input", this._saveHandler);
    this.handleEvent("refocus", () => {
      this.el.value = "";
      localStorage.removeItem("game-search");
      requestAnimationFrame(() => this.el.focus());
    });
    this.handleEvent("clear_and_refocus", () => {
      this.el.value = "";
      localStorage.removeItem("game-search");
      requestAnimationFrame(() => this.el.focus());
    });
  },
  destroyed() {
    this.el.removeEventListener("input", this._saveHandler);
  }
};

Hooks.GameListScroll = {
  mounted() {
    this.handleEvent("scroll_to_game", ({idx}) => {
      const card = document.getElementById("game-card-" + idx);
      if (card) {
        card.scrollIntoView({behavior: "smooth", block: "nearest"});
      }
    });

    // Restore the saved spot: ask the server to load back to the same row
    // depth, then land on the saved scroll offset once those rows render.
    const savedCount = parseInt(localStorage.getItem("rm:gamelist:count")) || 0;
    const savedScroll = parseInt(localStorage.getItem("rm:gamelist:scroll")) || 0;
    if (savedCount > 20) {
      this.pushEvent("restore_list_pos", {count: savedCount}, () => {
        requestAnimationFrame(() => window.scrollTo(0, savedScroll));
      });
    } else if (savedScroll > 0) {
      requestAnimationFrame(() => window.scrollTo(0, savedScroll));
    }

    // Persist scroll offset (debounced) so a return visit lands here.
    this._scrollHandler = () => {
      clearTimeout(this._scrollTimer);
      this._scrollTimer = setTimeout(() => {
        localStorage.setItem("rm:gamelist:scroll", window.scrollY);
      }, 150);
    };
    window.addEventListener("scroll", this._scrollHandler, {passive: true});

    this._keyHandler = (e) => {
      // Escape in search input: clear and refocus
      if (e.key === "Escape") {
        const searchInput = document.getElementById("game-search");
        if (searchInput && document.activeElement === searchInput) {
          searchInput.value = "";
          searchInput.focus();
          this.pushEvent("clear_search", {});
          e.preventDefault();
          return;
        }
      }

      // Down arrow from search input: select first game
      if (e.key === "ArrowDown") {
        const searchInput = document.getElementById("game-search");
        if (searchInput && document.activeElement === searchInput) {
          searchInput.blur();
          this.pushEvent("key_nav", {key: "ArrowDown"});
          e.preventDefault();
          return;
        }
      }

      // Up arrow on first game: refocus search with text selected
      if (e.key === "ArrowUp") {
        const firstCard = document.getElementById("game-card-0");
        if (firstCard && firstCard.style.outline) {
          const searchInput = document.getElementById("game-search");
          if (searchInput) {
            searchInput.focus();
            searchInput.select();
            this.pushEvent("key_nav", {key: "unselect"});
            e.preventDefault();
            return;
          }
        }
      }

      // Don't intercept when typing in an input
      if (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA" || e.target.isContentEditable) {
        return;
      }

      const keys = ["ArrowDown", "ArrowUp", "Enter", "e", "E"];
      if (keys.includes(e.key)) {
        e.preventDefault();
        this.pushEvent("key_nav", {key: e.key});
      }
    };
    window.addEventListener("keydown", this._keyHandler);
  },
  destroyed() {
    window.removeEventListener("keydown", this._keyHandler);
    window.removeEventListener("scroll", this._scrollHandler);
    clearTimeout(this._scrollTimer);
  }
};

Hooks.ScrollToMessage = {
  mounted() {
    this.el.addEventListener("click", () => {
      const targetId = this.el.getAttribute("data-target");
      const target = document.getElementById(targetId);
      if (target) {
        target.scrollIntoView({ behavior: "smooth", block: "start" });
        // Brief highlight
        target.style.transition = "background 0.3s";
        target.style.background = "var(--bg-subtle)";
        setTimeout(() => { target.style.background = ""; }, 1500);
      }
    });
  }
};

Hooks.ClipboardCopy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.getAttribute("data-clipboard-text");
      if (!text) return;
      const ok = await this.copy(text);
      this.feedback(ok);
    });
  },
  async copy(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (e) {
      /* fall through to execCommand */
    }
    // Fallback for older browsers / non-HTTPS
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand("copy");
      document.body.removeChild(ta);
      return ok;
    } catch (e) {
      return false;
    }
  },
  feedback(ok) {
    const orig = this.el.innerHTML;
    this.el.classList.add(ok ? "card-menu__item--ok" : "card-menu__item--err");
    this.el.innerHTML = ok ? "✓ Copied!" : "✕ Copy failed";
    if (window.showToast) showToast(ok ? "📋" : "⚠️", ok ? "Copied to clipboard!" : "Couldn't copy");
    setTimeout(() => {
      this.el.innerHTML = orig;
      this.el.classList.remove("card-menu__item--ok", "card-menu__item--err");
    }, 1500);
  }
};

// Voice dictation for the ask box. Click to speak; the transcript fills the
// target input and (on a final result) submits the form hands-free. Uses the
// browser Web Speech API; the button hides itself where it's unsupported.
Hooks.VoiceDictation = {
  mounted() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) {
      this.el.style.display = "none";
      return;
    }

    const targetId = this.el.getAttribute("data-target");
    const autoSubmit = this.el.getAttribute("data-autosubmit") === "true";
    const idleHTML = this.el.innerHTML;

    this.listening = false;
    this.rec = new SR();
    this.rec.lang = navigator.language || "en-US";
    this.rec.interimResults = true;
    this.rec.continuous = false;

    const input = () => document.getElementById(targetId);

    const stop = () => {
      this.listening = false;
      this.el.innerHTML = idleHTML;
      this.el.style.color = "var(--text-muted)";
    };

    this.rec.onresult = (e) => {
      const transcript = Array.from(e.results)
        .map((r) => r[0].transcript)
        .join("")
        .trim();
      const el = input();
      if (el) {
        el.value = transcript;
        el.dispatchEvent(new Event("input", { bubbles: true }));
      }
      if (e.results[e.results.length - 1].isFinal && autoSubmit && transcript !== "") {
        const form = el && el.closest("form");
        if (form) form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      }
    };

    this.rec.onerror = stop;
    this.rec.onend = stop;

    this._click = () => {
      if (this.listening) {
        this.rec.stop();
        stop();
        return;
      }
      const el = input();
      if (el && el.disabled) return;
      try {
        this.rec.start();
        this.listening = true;
        this.el.innerHTML = "🎙️";
        this.el.style.color = "var(--accent)";
        if (el) el.focus();
      } catch (_e) {
        stop();
      }
    };

    this.el.addEventListener("click", this._click);
  },
  destroyed() {
    if (this.rec) {
      try { this.rec.abort(); } catch (_e) {}
    }
    if (this._click) this.el.removeEventListener("click", this._click);
  }
};

// Persists setup-checklist checked items per-browser (per game) in localStorage.
// On connect, restores the saved set to the server; thereafter the server pushes
// "save_checklist" on every toggle/clear so storage stays in sync.
Hooks.ChecklistStore = {
  key() {
    return "rm:checklist:" + this.el.dataset.gameId;
  },
  mounted() {
    let saved = [];
    try {
      saved = JSON.parse(localStorage.getItem(this.key()) || "[]");
    } catch (_e) {
      saved = [];
    }
    if (Array.isArray(saved) && saved.length > 0) {
      this.pushEvent("checklist_restore", { keys: saved });
    }
    this.handleEvent("save_checklist", ({ game_id, keys }) => {
      // Ignore pushes for a different game's checklist.
      if (String(game_id) !== String(this.el.dataset.gameId)) return;
      if (keys && keys.length > 0) {
        localStorage.setItem(this.key(), JSON.stringify(keys));
      } else {
        localStorage.removeItem(this.key());
      }
    });
  }
};

Hooks.VoiceDefault = {
  key: "rm:default_voice",
  mounted() {
    let saved = "";
    try {
      saved = localStorage.getItem(this.key) || "";
    } catch (_e) {
      saved = "";
    }
    if (saved) {
      this.pushEvent("default_voice_restore", { voice: saved });
    }
    this.handleEvent("save_default_voice", ({ voice }) => {
      if (voice && voice !== "neutral") {
        localStorage.setItem(this.key, voice);
      } else {
        localStorage.removeItem(this.key);
      }
    });
  }
};

// Keyboard paging for the rulebook reader, shared by the inline source editors
// and the expanded modal. ← / h previous page, → / l next, f opens the expanded
// reader (inline only). Ignored while typing in a field so editing isn't
// hijacked. Window-level, but each instance only acts when it's the active
// reader: the modal always wins while open; otherwise the inline source under
// the mouse or holding focus.
Hooks.ReaderKeys = {
  mounted() {
    this._handler = (e) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const t = e.target;
      if (t && (t.isContentEditable ||
                t.tagName === "INPUT" ||
                t.tagName === "TEXTAREA" ||
                t.tagName === "SELECT")) return;
      if (!this._active()) return;

      const isModal = this.el.id === "reader-modal";
      const id = this.el.dataset.readerId;

      if (e.key === "ArrowLeft" || e.key === "h") {
        e.preventDefault();
        this.pushEvent("source_page_step", {id, delta: "-1"});
      } else if (e.key === "ArrowRight" || e.key === "l") {
        e.preventDefault();
        this.pushEvent("source_page_step", {id, delta: "1"});
      } else if (e.key === "f") {
        e.preventDefault();
        if (isModal) this.pushEvent("close_source", {});
        else this.pushEvent("expand_source", {id});
      }
    };
    window.addEventListener("keydown", this._handler);
  },
  // The modal owns the keys while open; otherwise the hovered/focused inline
  // source does. Stops every inline instance from paging at once.
  _active() {
    if (this.el.id === "reader-modal") return true;
    if (document.getElementById("reader-modal")) return false;
    return this.el.matches(":hover") || this.el.contains(document.activeElement);
  },
  destroyed() {
    window.removeEventListener("keydown", this._handler);
  }
};

Hooks.InfiniteScroll = {
  mounted() {
    this.observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        this.pushEvent("load_more", {});
      }
    });
    this.observer.observe(this.el);
  },
  destroyed() {
    this.observer.disconnect();
  }
};

let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
  params: () => ({
    _csrf_token: csrfToken,
    // Remembered game-list view (playable/mine/all) so it survives reloads.
    list_view: localStorage.getItem("rm:gamelist:view") || "",
    // Remembered cleanup strength (light|standard|aggressive). Restored in mount.
    clean_level: localStorage.getItem("rm:clean:level") || "",
    // Remembered game-edit tab per game ({gameId: tab}) so a refresh reopens it.
    edit_tab: localStorage.getItem("rm:edit:tab") || "",
    // Remembered rulebook reader page per source ({gameId: {srcId: page}}).
    reader_pages: localStorage.getItem("rm:reader:pages") || ""
  }),
  hooks: Hooks
});

// Force a <details> log panel open when a re-extraction starts (the inline panel
// is always in the DOM, so its phx-mounted won't re-fire on the live trigger).
window.addEventListener("phx:open_log", (e) => {
  const el = document.getElementById(e.detail.id);
  if (el) el.open = true;
});

// Persist the cleanup strength choice.
window.addEventListener("phx:save_clean_level", (e) => {
  localStorage.setItem("rm:clean:level", e.detail.level);
});

// Merge a value into a {gameId: ...} JSON blob in localStorage. Tolerates a
// corrupt/missing blob by starting fresh.
function mergeGameBlob(key, gameId, value) {
  let blob = {};
  try {
    blob = JSON.parse(localStorage.getItem(key) || "{}") || {};
  } catch (_) {
    blob = {};
  }
  blob[gameId] = value;
  localStorage.setItem(key, JSON.stringify(blob));
}

// Persist the game-edit tab per game so a refresh reopens the last one.
window.addEventListener("phx:save_edit_tab", (e) => {
  mergeGameBlob("rm:edit:tab", e.detail.game_id, e.detail.tab);
});

// Persist the rulebook reader page per source, nested under the game id.
window.addEventListener("phx:save_reader_page", (e) => {
  let blob = {};
  try {
    blob = JSON.parse(localStorage.getItem("rm:reader:pages") || "{}") || {};
  } catch (_) {
    blob = {};
  }
  const g = blob[e.detail.game_id] || {};
  g[e.detail.source_id] = e.detail.page;
  blob[e.detail.game_id] = g;
  localStorage.setItem("rm:reader:pages", JSON.stringify(blob));
});

// Keep --header-height in sync with the real sticky-header height so fixed/
// sticky layouts (Q&A page, game-list controls) sit flush beneath it with no
// gap. CSS ships a sensible fallback; this refines it to the measured value.
function syncHeaderHeight() {
  const header = document.querySelector(".header");
  if (header) {
    document.documentElement.style.setProperty("--header-height", header.offsetHeight + "px");
  }
  // Offset the whole sticky stack (header + any sticky list controls) so
  // scrollIntoView / scroll restore land cards below it instead of clipping
  // the top row under the bar.
  const headerH = header ? header.offsetHeight : 0;
  const controls = document.querySelector(".list-controls");
  const controlsH = controls ? controls.offsetHeight : 0;
  document.documentElement.style.scrollPaddingTop = (headerH + controlsH) + "px";
}
window.addEventListener("resize", syncHeaderHeight);
window.addEventListener("phx:page-loading-stop", syncHeaderHeight);
window.addEventListener("DOMContentLoaded", syncHeaderHeight);
syncHeaderHeight();

// Track first successful WebSocket connection on the LiveView root element.
// Classes phx-connected/phx-loading/phx-error are set on [data-phx-main], not body.
let mainEl = document.querySelector("[data-phx-main]");
if (mainEl) {
  let observer = new MutationObserver(() => {
    if (mainEl.classList.contains("phx-connected")) {
      mainEl.classList.add("phx-was-connected");
      observer.disconnect();
    }
  });
  observer.observe(mainEl, {attributes: true, attributeFilter: ["class"]});
}

// Only connect the LiveSocket when there are LiveView elements on the page.
// Connecting unconditionally on every page (e.g. /login) creates a WebSocket
// whose connect_info session is captured at connect-time. When the browser
// later navigates to a page with a LiveView, the same socket is reused with
// the stale session, causing on_mount to see the wrong auth state.
if (document.querySelector("[data-phx-main]")) {
  liveSocket.connect();
}

if ("serviceWorker" in navigator) {
  window.addEventListener("load", function() {
    navigator.serviceWorker.register("/sw.js").then(function(reg) {
      setInterval(function() { reg.update(); }, 60000);
    });
  });

  let refreshing = false;
  navigator.serviceWorker.addEventListener("controllerchange", function() {
    if (refreshing) return;
    refreshing = true;
    window.location.reload();
  });

  // Close all <details> dropdowns on LiveView page transition
  window.addEventListener("phx:page-loading-stop", () => {
    document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
  });
  // Also close on back-forward cache restore
  window.addEventListener("pageshow", (e) => {
    if (e.persisted) {
      document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
    }
  });

  // Close <details> on Escape key
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      document.querySelectorAll("details[open]").forEach(el => el.removeAttribute("open"));
    }
  });

  // Close <details> on click outside
  document.addEventListener("click", (e) => {
    document.querySelectorAll("details[open]").forEach(el => {
      if (!el.contains(e.target)) {
        el.removeAttribute("open");
      }
    });
  });
}

// Hamburger drawer toggle
(function() {
  var btn = document.getElementById('hamburger-btn');
  var drawer = document.getElementById('drawer');
  var overlay = document.getElementById('drawer-overlay');
  var closeBtn = document.getElementById('drawer-close');
  if (!btn || !drawer || !overlay) return;

  function open() { drawer.classList.add('open'); overlay.classList.add('open'); }
  function close() { drawer.classList.remove('open'); overlay.classList.remove('open'); }

  btn.addEventListener('click', open);
  closeBtn.addEventListener('click', close);
  overlay.addEventListener('click', close);

  // Close on Escape
  document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape' && drawer.classList.contains('open')) close();
  });
})();
