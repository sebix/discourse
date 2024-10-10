import { helperContext } from "discourse-common/lib/helpers";

export default function (element) {
  const caps = helperContext().capabilities;

  // disable on iPadOS
  // hacky, but prevents the composer from being moved off-screen
  // when tapping an already focused element

  if (caps.isIpadOS) {
    return;
  }

  element.focus();
  const len = element.value.length;
  element.setSelectionRange(len, len);

  // Scroll to the bottom, in case we're in a tall textarea
  element.scrollTop = 999999;
}
