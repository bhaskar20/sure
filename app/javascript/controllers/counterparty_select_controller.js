import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="counterparty-select"
// Picking "Add an account not in Sure" opens a dialog to name it instead of
// saving the review cell.
export default class extends Controller {
  static targets = ["select"];
  static values = { newUrl: String, current: String };

  intercept(event) {
    if (this.selectTarget.value !== "new_untracked") return;

    event.preventDefault();
    this.selectTarget.value = this.currentValue;
    Turbo.visit(this.newUrlValue, { frame: "modal" });
  }
}
