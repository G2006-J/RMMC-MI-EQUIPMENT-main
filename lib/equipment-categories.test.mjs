import assert from "node:assert/strict";
import test from "node:test";
import { displayEquipmentCategory, isHiddenEquipmentCategory } from "./equipment-categories.mjs";

test("retired categories are hidden and not displayed", () => {
  for (const category of ["General", "Accessories", "Networking Equipment", "Projector"]) {
    assert.equal(isHiddenEquipmentCategory(category), true);
    assert.equal(displayEquipmentCategory(category), "");
  }
});

test("legacy computer categories are hidden and displayed under the current name", () => {
  for (const category of ["Computer and Laptops", "Computers and Laptops"]) {
    assert.equal(isHiddenEquipmentCategory(category), true);
    assert.equal(displayEquipmentCategory(category), "ICT Equipment");
  }
});

test("current equipment categories remain visible", () => {
  assert.equal(isHiddenEquipmentCategory("ICT Equipment"), false);
  assert.equal(displayEquipmentCategory("ICT Equipment"), "ICT Equipment");
});
