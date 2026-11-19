const HIDDEN_EQUIPMENT_CATEGORIES = new Set([
  "general",
  "accessories",
  "networking equipment",
  "projector",
  "computer and laptops",
  "computers and laptops",
]);

const ICT_EQUIPMENT_ALIASES = new Set(["computer and laptops", "computers and laptops"]);

function normalizeCategoryName(name) {
  return String(name || "").trim().toLowerCase();
}

export function isHiddenEquipmentCategory(name) {
  return HIDDEN_EQUIPMENT_CATEGORIES.has(normalizeCategoryName(name));
}

export function displayEquipmentCategory(name) {
  const normalizedName = normalizeCategoryName(name);
  if (ICT_EQUIPMENT_ALIASES.has(normalizedName)) return "ICT Equipment";
  if (HIDDEN_EQUIPMENT_CATEGORIES.has(normalizedName)) return "";
  return String(name || "").trim();
}
