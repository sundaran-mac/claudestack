// Run inside reader.html by `ClaudeStack --scroll-test`. Simulates a small scroll up by the
// user, then the updates the app sends every half second, and reports how far the view moved.
(function () {
  const s = document.getElementById("scroll");
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const last = window.__items[window.__items.length - 1];
  (async () => {
    s.scrollTop = s.scrollHeight;
    await wait(200);
    // The user scrolls up a little: a wheel event, then the view moves 40 px.
    s.dispatchEvent(new WheelEvent("wheel", { deltaY: -40, bubbles: true }));
    s.scrollTop -= 40;
    await wait(200);
    const before = s.scrollTop;
    for (let i = 1; i <= 6; i++) {
      const bumped = JSON.parse(JSON.stringify(last));
      bumped.v = 1000 + i;
      bumped.blocks.push({ type: "tool", name: "Bash", detail: "step " + i, id: "t" + i });
      CS.setItems({ sid: "test", hasMore: false, items: window.__items.slice(0, -1).concat([bumped]) });
      CS.setState(Object.assign({}, window.__state, { detail: "step " + i }));
      await wait(150);
    }
    const after = s.scrollTop;
    const button = !document.getElementById("latest").hidden;
    // Now the user goes back to the bottom. New messages must be followed again.
    s.scrollTop = s.scrollHeight;
    await wait(200);
    for (let i = 7; i <= 9; i++) {
      const bumped = JSON.parse(JSON.stringify(last));
      bumped.v = 2000 + i;
      for (let k = 1; k <= i; k++) bumped.blocks.push({ type: "text", text: "New line " + k + "\n\nmore text" });
      CS.setItems({ sid: "test", hasMore: false, items: window.__items.slice(0, -1).concat([bumped]) });
      await wait(150);
    }
    const gap = Math.round(s.scrollHeight - s.scrollTop - s.clientHeight);
    window.__result = JSON.stringify({ movedWhileReading: Math.round(after - before), jumpButton: button, gapAtEnd: gap });
  })();
})();
