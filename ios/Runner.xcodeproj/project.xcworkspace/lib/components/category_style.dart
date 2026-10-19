import 'package:flutter/material.dart';

const categoryIcons = <String, IconData>{
  'restaurant': Icons.restaurant_rounded,
  'coffee': Icons.local_cafe_rounded,
  'transport': Icons.directions_bus_rounded,
  'shopping': Icons.shopping_bag_rounded,
  'home': Icons.home_rounded,
  'movie': Icons.movie_rounded,
  'health': Icons.favorite_rounded,
  'school': Icons.school_rounded,
  'pets': Icons.pets_rounded,
  'travel': Icons.flight_rounded,
  'salary': Icons.work_rounded,
  'gift': Icons.card_giftcard_rounded,
  'other': Icons.category_rounded,
};

String categoryIconKey(String name, String? icon) {
  if (categoryIcons.containsKey(icon)) return icon!;
  return switch (name) {
    '餐饮' => 'restaurant', '交通' => 'transport', '购物' => 'shopping',
    '住房' => 'home', '娱乐' => 'movie', '工资' => 'salary', '奖金' => 'gift',
    _ => 'other',
  };
}

Color categoryDisplayColor(String? value, {bool income = false}) {
  final parsed = int.tryParse((value ?? '').replaceFirst('#', ''), radix: 16);
  return parsed == null ? (income ? const Color(0xFF169B83) : const Color(0xFF1677F2))
    : Color(0xFF000000 | (parsed & 0xFFFFFF));
}
