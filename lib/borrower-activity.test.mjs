import assert from "node:assert/strict";
import test from "node:test";
import { getBorrowerActivityItems } from "./borrower-activity.mjs";

test("reported quantities are removed from active borrower activity", () => {
  const items = getBorrowerActivityItems([
    {
      borrowing_item_id: 1,
      item_status: "released",
      quantity: 4,
      damage_loss_reports: [{ quantity_affected: 2 }],
    },
    {
      borrowing_item_id: 2,
      item_status: "released",
      quantity: 1,
      damage_loss_reports: [{ quantity_affected: 1 }],
    },
    {
      borrowing_item_id: 3,
      item_status: "requested",
      quantity: 2,
      damage_loss_reports: [],
    },
  ]);

  assert.deepEqual(items.map((item) => [item.borrowing_item_id, item.quantity]), [
    [1, 2],
    [3, 2],
  ]);
});

test("multiple reports cannot make the displayed remaining quantity negative", () => {
  const [item] = getBorrowerActivityItems([{
    borrowing_item_id: 1,
    item_status: "released",
    quantity: 2,
    damage_loss_reports: [{ quantity_affected: 2 }, { quantity_affected: 1 }],
  }]);

  assert.equal(item, undefined);
});
