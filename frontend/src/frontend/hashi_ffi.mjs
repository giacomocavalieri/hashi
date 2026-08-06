export function read_app_json_data(id) {
  return document.getElementById(id)?.textContent ?? "";
}

export function do_island_under_pointer([x, y], on_enter, on_exit) {
  const island = document.elementFromPoint(x, y)?.closest(".hashi-island");

  if (island == null) {
    on_exit();
  } else {
    on_enter([parseInt(island.dataset.x), parseInt(island.dataset.y)]);
  }
}

export function do_after(milliseconds, run) {
  setTimeout(() => {
    run();
  }, milliseconds);

  return undefined;
}

export async function do_share(title, message, on_shared) {
  if (!navigator.share) {
    // If the share API is not available in the browser, then we fall back to
    // copying to the system's clipboard.
    try {
      await navigator.clipboard.writeText(message);
      on_shared(true);
    } catch (exception) {
      console.log(exception);
    }
  } else {
    // Otherwise we use the share API.
    try {
      await navigator.share({ title, text: message });
      on_shared(false);
    } catch (exception) {
      // If for some reason sharing with the share API fails (for example we
      // might be missing the permission), we try and fallback to the clipboard
      // api.
      try {
        await navigator.clipboard.writeText(message);
        on_shared(true);
      } catch (exception) {
        console.log(exception);
      }
    }
  }
}

export function write_local_storage(key, value) {
  localStorage.setItem(key, value);
}

export function read_local_storage(key) {
  const value = localStorage.getItem(key);
  return value ? value : "";
}
