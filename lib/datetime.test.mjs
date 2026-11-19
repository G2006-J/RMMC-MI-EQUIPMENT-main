import assert from "node:assert/strict";
import test from "node:test";
import {
  formatManilaDate,
  formatManilaDateTime,
  isManilaDateTimeCurrent,
  manilaDateKey,
} from "./datetime.mjs";

test("Manila date keys follow the local calendar day across UTC midnight", () => {
  assert.equal(manilaDateKey(new Date("2026-11-19T16:00:00Z")), "2026-11-20");
});

test("same-day reservations are current only until their Manila end time", () => {
  assert.equal(isManilaDateTimeCurrent("2026-11-20", "17:00:00", new Date("2026-11-20T08:59:00Z")), true);
  assert.equal(isManilaDateTimeCurrent("2026-11-20", "17:00:00", new Date("2026-11-20T09:00:00Z")), false);
});

test("date-only values preserve their calendar day in Manila", () => {
  assert.equal(formatManilaDate("2026-11-14"), "Nov 14, 2026");
});

test("date-time values are rendered in Asia/Manila", () => {
  assert.equal(formatManilaDateTime("2026-11-14T00:00:00Z"), "Nov 14, 2026, 8:00 AM");
});
