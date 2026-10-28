-- how-to lessons for sudoku (loaded only when the how-to screen opens)
return {
  { title = "THE RULE", body = "EVERY ROW, COLUMN AND BOX HOLDS 1 TO 9.",
    detail = "NO DIGIT TWICE IN ANY OF THEM.", before = "123456789", after = nil, armed = 0 },
  { title = "WRITING", body = "PICK A DIGIT FROM THE PAD, THEN CONFIRM A CELL.",
    detail = "EVERY COPY OF IT IS MARKED.", before = "A.C.....I", after = "A.C.5...I", armed = 5 },
  { title = "CLEARING", body = "CONFIRM YOUR OWN DIGIT AGAIN TO RUB IT OUT.",
    detail = "CONFIRM A CLUE TO PICK ITS DIGIT UP.", before = "A.C.5...I", after = "A.C.....I", armed = 5 },
  { title = "PENCIL", body = "CONFIRM AN ARMED KEY TWICE, THEN CONFIRM A CELL.",
    detail = "CONFIRM AGAIN TO RUB IT OUT.", before = "A.C.....I", after = "A.C.p...I", armed = 0 },
  { title = "MISTAKES", body = "A DIGIT THAT CLASHES TURNS BLACK.",
    detail = "HINT NAMES A CELL YOU CAN SOLVE.", before = "A.C.5...I", after = "A.C!!...I", armed = 5 },
}
