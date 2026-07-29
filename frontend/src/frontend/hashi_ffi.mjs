export function read_app_json_data(id) {
  return document.getElementById(id)?.textContent ?? "";
}

export function do_after(milliseconds, run) {
  setTimeout(() => {
    run();
  }, milliseconds);

  return undefined;
}

export function do_handle_moved_pointer_event(
  event,
  on_island_enter,
  on_island_exit,
  on_point,
) {
  const [svg] = document.getElementsByClassName("hashi-grid");
  const point = svg.createSVGPoint();
  point.x = event.x;
  point.y = event.y;
  const { x, y } = point.matrixTransform(svg.getScreenCTM().inverse());
  on_point([x, y]);

  const island = document
    .elementFromPoint(event.x, event.y)
    ?.closest(".hashi-island");

  if (island == null) {
    // TODO) Probably something to check if we're still close to the previous
    // island, we want some leeway
    on_island_exit();
  } else {
    on_island_enter([parseInt(island.dataset.x), parseInt(island.dataset.y)]);
  }
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
      console.log(exception);
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
