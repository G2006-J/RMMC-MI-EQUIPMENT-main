export function getBorrowerActivityItems(items) {
  return (items || [])
    .map((item) => {
      const quantity = Number(item.quantity || 1);
      const reportedQuantity = (item.damage_loss_reports || [])
        .reduce((total, report) => total + Number(report.quantity_affected || 0), 0);
      const remainingQuantity = item.item_status === "released"
        ? Math.max(0, quantity - reportedQuantity)
        : quantity;

      return {
        ...item,
        original_quantity: quantity,
        quantity: remainingQuantity,
      };
    })
    .filter((item) => item.item_status !== "released" || item.quantity > 0);
}
