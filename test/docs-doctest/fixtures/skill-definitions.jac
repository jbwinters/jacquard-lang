limit = 100

add-tax(amount, rate) = real.mul(amount, real.add(1.0, rate))

resize(image, scale: ratio) = (image, ratio)

increment = fn (n) -> add(n, 1)

answer : () ->{} Int
answer() = increment(41)

answer()

resize("photo.png", scale: 2)
