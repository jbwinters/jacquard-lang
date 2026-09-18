printf 'type Tier = | Bronze | Gold\nrank(t) = match t { | Bronze -> 1 | Gold -> 2 }\n' > model.jac
printf 'rank(Gold)\n' > entry.jac
printf 'add(rank(Bronze), rank(Gold))\n' > other-entry.jac
jacquard store add model-store model.jac
jacquard run entry.jac --store model-store
jacquard run other-entry.jac --store model-store
