/// 食事種別
enum MealType {
  eatingOut('eating_out', '外食'),
  homeCooking('home_cooking', '自炊'),
  delivery('delivery', '出前');

  const MealType(this.value, this.label);

  final String value;
  final String label;

  static MealType fromValue(String value) {
    return MealType.values.firstWhere((e) => e.value == value);
  }
}
