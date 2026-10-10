package protocol

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"polyquery/internal/engine"
)

func session(t *testing.T, cfg engine.Config, lines ...string) []map[string]any {
	t.Helper()
	h := NewHandler(engine.New(cfg))
	var out bytes.Buffer
	if err := h.RunSession(strings.NewReader(strings.Join(lines, "\n")+"\n"), &out); err != nil {
		t.Fatal(err)
	}
	var resps []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("invalid response line %q: %v", l, err)
		}
		resps = append(resps, m)
	}
	return resps
}

func code(m map[string]any) string {
	if e, ok := m["error"].(map[string]any); ok {
		return e["code"].(string)
	}
	return ""
}

func TestSession(t *testing.T) {
	cfg := engine.DefaultConfig()
	cfg.DataDir = t.TempDir()
	resps := session(t, cfg,
		`{"op":"load","id":"L","table":"t","format":"csv","data":"a,b\n1,x\n2,\"q\"\"\"\n"}`,
		``,
		`not json`,
		`{"op":"query","id":{"k":[1]},"sql":"SELECT b, a * 1.5 AS c FROM t ORDER BY a"}`,
		`{"op":"tables"}`,
		`{"op":"schema","table":"T"}`,
		`{"op":"frobnicate"}`,
		`{"op":"query","sql":42}`,
		`{"op":"sleep","ms":1}`,
		`{"op":"query","sql":"SELECT a FROM t","options":{"result":"count"}}`,
	)
	if len(resps) != 9 {
		t.Fatalf("got %d responses", len(resps))
	}
	if resps[0]["id"] != "L" || resps[0]["row_count"] != 2.0 {
		t.Errorf("load response: %v", resps[0])
	}
	if code(resps[1]) != "INVALID_REQUEST" || resps[1]["id"] != nil {
		t.Errorf("bad json response: %v", resps[1])
	}
	q := resps[2]
	if id, _ := json.Marshal(q["id"]); string(id) != `{"k":[1]}` {
		t.Errorf("id not echoed: %s", id)
	}
	if rows, _ := json.Marshal(q["rows"]); string(rows) != `[["x","1.5"],["q\"","3.0"]]` {
		t.Errorf("rows = %s", rows)
	}
	if cols, _ := json.Marshal(q["columns"]); string(cols) != `[{"name":"b","type":"STRING"},{"name":"c","type":"DECIMAL(18,1)"}]` {
		t.Errorf("columns = %s", cols)
	}
	if tables, _ := json.Marshal(resps[3]["tables"]); string(tables) != `[{"name":"t","row_count":2}]` {
		t.Errorf("tables = %s", tables)
	}
	if resps[4]["table"] != "t" {
		t.Errorf("schema = %v", resps[4])
	}
	for i, want := range map[int]string{5: "INVALID_REQUEST", 6: "INVALID_REQUEST", 7: "INVALID_REQUEST"} {
		if code(resps[i]) != want {
			t.Errorf("response %d: %v, want %s", i, resps[i], want)
		}
	}
	if _, has := resps[8]["rows"]; has || resps[8]["row_count"] != 2.0 {
		t.Errorf("count-only response: %v", resps[8])
	}
}

func TestExecArray(t *testing.T) {
	h := NewHandler(engine.New(engine.DefaultConfig()))
	var out bytes.Buffer
	if err := h.RunExec([]byte(`[{"op":"version","id":1},{"op":"query","sql":"SELECT 1 AS x"}]`), &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"spec_version":"1.0.0"`) || !strings.Contains(lines[1], `"rows":[[1]]`) {
		t.Errorf("exec output: %q", out.String())
	}
}

func TestStringEscaping(t *testing.T) {
	got := string(appendString(nil, "a\"b\\c\td\x01é\n"))
	if got != `"a\"b\\c\td\u0001é\n"` {
		t.Errorf("appendString = %s", got)
	}
}
