import assert from "node:assert/strict";
import test from "node:test";
import { getErrorMessage, PENDING_BORROWER_MESSAGE } from "./backend-error.mjs";

test("returns pending borrower guidance", () => {
  assert.equal(
    getErrorMessage({ message: "Your borrower account is pending approval or inactive." }),
    PENDING_BORROWER_MESSAGE,
  );
});

test("returns ordinary application errors", () => {
  assert.equal(
    getErrorMessage({ message: "Choose a valid future reservation date range." }),
    "Choose a valid future reservation date range.",
  );
});

test("uses a safe fallback for an empty backend error", () => {
  assert.equal(
    getErrorMessage({}),
    "Something went wrong. Please try again.",
  );
});
