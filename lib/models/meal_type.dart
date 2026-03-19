/// 食事種別
enum MealType {
  eatingOut('eating_out', '外食'),
  homeCooking('home_cooking', '自炊'),
  takeout('takeout', 'テイクアウト'),
  delivery('delivery', 'デリバリー'),
  snack('snack', '間食・おやつ'),
  other('other', 'その他');

  const MealType(this.value, this.label);

  final String value;
  final String label;

  static MealType fromValue(String value) {
    return MealType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => MealType.other,
    );
  }
}
