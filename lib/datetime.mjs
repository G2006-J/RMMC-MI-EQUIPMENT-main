function parseDate(value) {
  if (value === null || value === undefined || value === "") return null;
  const text = String(value);
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(text) ? `${text}T00:00:00+08:00` : text);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function manilaDateKey(value = new Date()) {
  const parts = new Intl.DateTimeFormat("en", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: "Asia/Manila",
  }).formatToParts(value);
  const part = (type) => parts.find((item) => item.type === type)?.value;
  return `${part("year")}-${part("month")}-${part("day")}`;
}

export function isManilaDateTimeCurrent(dateValue, timeValue, now = new Date()) {
  if (!dateValue) return false;
  const endDateTime = new Date(`${String(dateValue)}T${String(timeValue || "23:59:59")}+08:00`);
  return !Number.isNaN(endDateTime.getTime()) && endDateTime.getTime() > now.getTime();
}

export function formatManilaDate(value) {
  const date = parseDate(value);
  if (!date) return value ? String(value) : "";
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeZone: "Asia/Manila",
  }).format(date);
}

export function formatManilaDateTime(value) {
  const date = parseDate(value);
  if (!date) return value ? String(value) : "";
  return new Intl.DateTimeFormat("en", {
    dateStyle: "medium",
    timeStyle: "short",
    timeZone: "Asia/Manila",
  }).format(date);
}
