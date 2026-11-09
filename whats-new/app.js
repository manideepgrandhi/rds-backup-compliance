(function () {
  const q = document.getElementById("q");
  const cards = Array.from(document.querySelectorAll(".card[data-search]"));
  const count = document.getElementById("count");
  const empty = document.getElementById("empty");
  const total = cards.length;

  function normalize(s) {
    return (s || "").toLowerCase().trim();
  }

  function render() {
    const term = normalize(q.value);
    let shown = 0;
    for (const card of cards) {
      const hay = card.getAttribute("data-search") || "";
      const ok = !term || hay.includes(term);
      card.classList.toggle("hidden", !ok);
      if (ok) shown += 1;

      // highlight matches in feature list text only
      const items = card.querySelectorAll(".features li");
      for (const li of items) {
        const raw = li.getAttribute("data-text") || li.textContent;
        li.setAttribute("data-text", raw);
        if (!term) {
          li.textContent = raw;
          continue;
        }
        const lower = raw.toLowerCase();
        const idx = lower.indexOf(term);
        if (idx < 0) {
          li.textContent = raw;
          continue;
        }
        const before = raw.slice(0, idx);
        const match = raw.slice(idx, idx + term.length);
        const after = raw.slice(idx + term.length);
        li.textContent = "";
        li.appendChild(document.createTextNode(before));
        const mark = document.createElement("mark");
        mark.textContent = match;
        li.appendChild(mark);
        li.appendChild(document.createTextNode(after));
      }
    }
    count.textContent = term
      ? `${shown} of ${total} releases`
      : `${total} releases`;
    empty.classList.toggle("show", shown === 0);
  }

  q.addEventListener("input", render);
  render();
})();
