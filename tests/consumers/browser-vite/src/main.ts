import "@rendered-motion/element/auto";

if (customElements.get("rendered-motion") === undefined) {
  throw new Error("auto entry did not register the element");
}
