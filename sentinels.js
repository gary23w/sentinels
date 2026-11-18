for (const group of document.querySelectorAll("[data-tabs]")) {
  const tabList = group.querySelector("[data-tab-list]");
  const buttons = [...tabList.querySelectorAll("[data-panel]")];
  const panels = buttons.map(button => document.getElementById(button.dataset.panel));
  const status = group.querySelector(".copy-status");

  function activate(selected) {
    for (const [index, button] of buttons.entries()) {
      const active = index === selected;
      button.setAttribute("aria-selected", String(active));
      button.tabIndex = active ? 0 : -1;
      panels[index].hidden = !active;
    }
    if (status) status.textContent = "";
  }

  for (const [index, button] of buttons.entries()) {
    const panel = panels[index];
    button.id = `tab-${panel.id}`;
    button.setAttribute("role", "tab");
    button.setAttribute("aria-controls", panel.id);
    panel.setAttribute("role", "tabpanel");
    panel.setAttribute("aria-labelledby", button.id);
    panel.tabIndex = 0;

    button.addEventListener("click", () => activate(index));
    button.addEventListener("keydown", event => {
      let next;
      switch (event.key) {
        case "ArrowRight": next = (index + 1) % buttons.length; break;
        case "ArrowLeft": next = (index + buttons.length - 1) % buttons.length; break;
        case "Home": next = 0; break;
        case "End": next = buttons.length - 1; break;
        default: return;
      }
      event.preventDefault();
      activate(next);
      buttons[next].focus();
    });
  }

  tabList.setAttribute("role", "tablist");
  activate(0);
  tabList.hidden = false;
}

for (const button of document.querySelectorAll("[data-copy]")) {
  const code = document.getElementById(button.dataset.copy);
  const status = button.closest("[data-tabs]").querySelector(".copy-status");
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(code.textContent);
      status.textContent = "Command copied.";
    } catch {
      const command = document.createRange();
      command.selectNodeContents(code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(command);
      status.textContent = "Command selected. Use your keyboard or browser menu to copy it.";
    }
  });
  button.hidden = false;
}
