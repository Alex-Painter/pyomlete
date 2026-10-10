import Foundation

/// A best guess at an item's aisle, so a new item appears in the right place
/// the moment it is typed. The server's `/categorize` answer replaces it a
/// moment later. A port of `client/src/lib/guessCategory.ts`; keep the two in step.
nonisolated func guessCategory(_ name: String, categories: [String], existing: [ListItem] = []) -> String {
    let lower = name.trimmed.lowercased()
    if let same = existing.first(where: { $0.name.lowercased() == lower }) { return same.category }

    for (category, pattern) in aisleKeywords where categories.contains(category) && lower.matches(pattern) {
        return category
    }
    return categories.contains("Other") || categories.isEmpty ? "Other" : categories[categories.count - 1]
}

nonisolated private let aisleKeywords: [(category: String, pattern: String)] = [
    (
        "Fresh Produce",
        #"\b(apple|banana|lemon|lime|orange|onion|shallot|garlic|ginger|potato|tomato|pepper|chilli|chili|carrot|celery|leek|spinach|lettuce|salad|rocket|kale|cabbage|broccoli|cauliflower|courgette|zucchini|aubergine|eggplant|mushroom|avocado|cucumber|herb|parsley|coriander|cilantro|basil|mint|thyme|rosemary|berr|grape|pear|peach|plum|mango|melon|squash|pumpkin|beetroot|sweetcorn|pea|bean sprout|spring onion|fruit|veg)"#
    ),
    (
        "Meat & Fish",
        #"\b(chicken|beef|pork|lamb|mince|bacon|sausage|ham|chorizo|steak|turkey|duck|salmon|cod|haddock|tuna|prawn|shrimp|fish|mackerel|anchov)"#
    ),
    (
        "Dairy & Eggs",
        #"\b(milk|cream|butter|cheese|cheddar|parmesan|mozzarella|feta|halloumi|yog(h)?urt|egg|crème|creme|ricotta|mascarpone)"#
    ),
    ("Bakery", #"\b(bread|loaf|baguette|roll|bagel|wrap|tortilla|pitta|pita|naan|croissant|bun)"#),
    ("Frozen", #"\b(frozen|ice cream|ice)"#),
    ("Drinks", #"\b(juice|wine|beer|cider|coffee|tea\b|squash|cola|lemonade|water|gin|vodka|whisky)"#),
    (
        "Household",
        #"\b(soap|detergent|bleach|bin bag|foil|cling|toilet|kitchen roll|tissue|sponge|washing|shampoo|toothpaste|battery|batteries)"#
    ),
    (
        "Pantry & Dry Goods",
        #"\b(rice|pasta|spaghetti|penne|noodle|flour|sugar|salt|oil|vinegar|stock|tin|can|beans|lentil|chickpea|oats|cereal|honey|jam|sauce|ketchup|mayo|mustard|spice|cumin|paprika|cinnamon|nut|seed|chocolate|biscuit|crisps|coconut milk|passata|puree)"#
    ),
]
