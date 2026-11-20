export const PENDING_BORROWER_MESSAGE =
  "No active borrower record is linked to your account. An administrator or property custodian must approve your borrower access before you can submit or view borrowing requests.";

export function getErrorMessage(error) {
  const message =
    typeof error?.message === "string" && error.message.trim()
      ? error.message.trim()
      : "Something went wrong. Please try again.";
  const details =
    typeof error?.details === "string" && error.details.trim()
      ? error.details.trim()
      : "";
  const hint =
    typeof error?.hint === "string" && error.hint.trim()
      ? error.hint.trim()
      : "";
  const code =
    typeof error?.code === "string" && error.code.trim()
      ? error.code.trim()
      : "";
  const constraint = typeof error?.constraint === "string" ? error.constraint : "";

  if (/Your borrower account is pending approval or inactive|No active borrower record matches your signed-in email/i.test(message)) {
    return PENDING_BORROWER_MESSAGE;
  }
  if (
    /equipment_asset_code_key/i.test(`${constraint} ${message}`)
    || (code === "23505" && /asset[_ ]code/i.test(`${message} ${details}`))
  ) {
    return "An equipment record with this asset code already exists. Choose a different asset code.";
  }
  if (
    /report_borrowing_item_condition/i.test(message)
    && /could not find|does not exist|schema cache/i.test(message)
  ) {
    return "Damage and loss reporting is temporarily unavailable. Please contact an administrator.";
  }
  if (/unresolved report of this type already exists/i.test(message)) {
    return "A damage or loss report for this item is already open. Please wait for review or contact a property custodian.";
  }
  if (/email rate limit exceeded|too many requests/i.test(message)) {
    return "Email delivery is temporarily limited. Please try again later.";
  }
  if (/error sending confirmation email|error sending.*email/i.test(message)) {
    return "The confirmation email could not be sent. Please try again later.";
  }
  if (
    details
    || hint
    || (/^[0-9A-Z]{5}$/i.test(code) && code !== "P0001")
    || /permission denied|constraint|row-level security|relation .* does not exist|column .* does not exist|schema cache|could not find the .* function|function .* does not exist|sqlstate|postgres|database|sql|query|statement|internal server error|failed to fetch|fetch failed|pgrst/i.test(message)
  ) {
    return "The action could not be completed. Please try again.";
  }
  if (code === "P0001") return message;
  return message;
}
