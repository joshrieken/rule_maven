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
    this.scrollToBottom();
    this.handleEvent("scroll_bottom", () => this.scrollToBottom());
  },
  updated() {
    this.scrollToBottom();
  },
  destroyed() {
    document.documentElement.style.overflow = "";
    document.body.style.overflow = "";
  },
  scrollToBottom() {
    const el = this.el;
    requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
  }
};

Hooks.Refocus = {
  mounted() {
    this.handleEvent("refocus", () => {
      this.el.value = "";
      requestAnimationFrame(() => this.el.focus());
    });
    this.handleEvent("clear_and_refocus", () => {
      this.el.value = "";
      requestAnimationFrame(() => this.el.focus());
    });
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
}
