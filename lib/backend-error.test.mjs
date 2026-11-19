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

test("explains an unresolved damage or loss report", () => {
  assert.equal(
    getErrorMessage({ message: "An unresolved report of this type already exists for the borrowed item.", code: "P0001" }),
    "A damage or loss report for this item is already open. Please wait for review or contact a property custodian.",
  );
});

test("shows safe validation messages returned by database workflows", () => {
  assert.equal(
    getErrorMessage({ message: "Only an active borrowed item can be reported.", code: "P0001" }),
    "Only an active borrowed item can be reported.",
  );
});

test("identifies when the borrower-reporting migration is missing", () => {
  assert.equal(
    getErrorMessage({
      message: "Could not find the function public.report_borrowing_item_condition in the schema cache.",
      code: "PGRST202",
    }),
    "Damage and loss reporting is not enabled. Apply the borrower damage/loss reporting migration to the Supabase database.",
  );
});

test("backend diagnostics log the message as visible text", () => {
  const logged = [];
  const originalError = console.error;
  console.error = (...values) => logged.push(values.join(" "));
  try {
    getErrorMessage({ message: "Database rejected the report.", code: "42501", details: "Permission denied." });
  } finally {
    console.error = originalError;
  }
  assert.match(logged[0], /Database rejected the report/);
  assert.match(logged[0], /42501/);
  assert.match(logged[0], /Permission denied/);
});
