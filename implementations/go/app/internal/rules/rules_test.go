package rules

import "testing"

func TestParseRules(t *testing.T) {
	rs, err := ParseRules("r", []byte("# c\ngroceries = Whole Foods*, trader joe?s\n\ncoffee = café*\ngroceries = REWE*\n"))
	if err != nil {
		t.Fatal(err)
	}
	want := []Rule{{1, "groceries", "WHOLE FOODS*"}, {2, "groceries", "TRADER JOE?S"}, {3, "coffee", "CAFé*"}, {4, "groceries", "REWE*"}}
	if len(rs) != len(want) {
		t.Fatalf("rules = %v", rs)
	}
	for i := range want {
		if rs[i] != want[i] {
			t.Errorf("rule %d = %v, want %v", i, rs[i], want[i])
		}
	}
	for _, bad := range []string{"groceries = SAFE_WAY\n", "groceries = 100%\n", "groceries = a,,b\n", "Groceries = x\n",
		"uncategorized = x\n", "[x]\n", "groceries\n", "groceries = \n"} {
		if _, err := ParseRules("r", []byte(bad)); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestParseBudgets(t *testing.T) {
	bs, err := ParseBudgets("b", []byte("groceries = 600\ncoffee = 30.5\n"))
	if err != nil || len(bs) != 2 || bs[1] != (Budget{"coffee", "30.5"}) {
		t.Fatalf("budgets = %v, %v", bs, err)
	}
	for _, bad := range []string{"a = 12.345\n", "a = -1\n", "a = 1.\n", "a = .5\n", "a = 1\na = 2\n", "a = 12345678901234567\n"} {
		if _, err := ParseBudgets("b", []byte(bad)); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if _, err := ParseBudgets("b", []byte("a = 1234567890123456.99\n")); err != nil {
		t.Errorf("16 digits rejected: %v", err)
	}
}
