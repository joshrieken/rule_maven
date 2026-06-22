let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");

let Hooks = {};
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
    this.scrollToLatestAnswer();
    this.handleEvent("scroll_bottom", () => this.scrollToBottom());
  },
  updated() {
    this.scrollToLatestAnswer();
  },
  destroyed() {
    document.documentElement.style.overflow = "";
    document.body.style.overflow = "";
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
    this.el.addEventListener("click", () => {
      const text = this.el.getAttribute("data-clipboard-text");
      if (!text) return;
      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(() => {
          const origHTML = this.el.innerHTML;
          this.el.innerHTML = "✓ Copied";
          setTimeout(() => { this.el.innerHTML = origHTML; }, 1500);
        });
      } else {
        // Fallback for older browsers / non-HTTPS
        const ta = document.createElement("textarea");
        ta.value = text;
        ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta);
        ta.select();
        document.execCommand("copy");
        document.body.removeChild(ta);
        const origHTML = this.el.innerHTML;
        this.el.innerHTML = "✓ Copied";
        setTimeout(() => { this.el.innerHTML = origHTML; }, 1500);
      }
    });
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
  params: {_csrf_token: csrfToken},
  hooks: Hooks
});

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
