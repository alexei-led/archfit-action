// Command validate checks archfit report envelopes against the vendored App schema
// and against the App decoder's rules that JSON Schema cannot express.
//
// Usage: validate SCHEMA ENVELOPE[=PAYLOAD]...
//
// ENVELOPE is the exact X-Archfit-Envelope header value the action sends. With
// PAYLOAD, payload_digest must also be the sha256 of the payload's bytes.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

// maxEnvelopeBytes is the App decoder's raw size limit (internal/wire/envelope).
const maxEnvelopeBytes = 8192

// integerBits are the App decoder's integer sizes; the schema says only "integer".
var integerBits = map[string]int{"pull_request": 32, "run_id": 64, "run_attempt": 32}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: validate SCHEMA ENVELOPE[=PAYLOAD]...")
		os.Exit(2)
	}
	schema, err := compile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	failed := false
	for _, arg := range os.Args[2:] {
		envelope, payload, _ := strings.Cut(arg, "=")
		if err := check(schema, envelope, payload); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %v\n", envelope, err)
			failed = true
			continue
		}
		fmt.Printf("%s: ok\n", envelope)
	}
	if failed {
		os.Exit(1)
	}
}

func compile(path string) (*jsonschema.Schema, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	doc, err := jsonschema.UnmarshalJSON(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	const url = "file:///envelope.v1.schema.json"
	c := jsonschema.NewCompiler()
	if err := c.AddResource(url, doc); err != nil {
		return nil, err
	}
	return c.Compile(url)
}

func check(schema *jsonschema.Schema, envelopePath, payloadPath string) error {
	raw, err := os.ReadFile(envelopePath)
	if err != nil {
		return err
	}
	switch {
	case len(raw) > maxEnvelopeBytes:
		return fmt.Errorf("%d bytes; the App accepts at most %d", len(raw), maxEnvelopeBytes)
	case bytes.ContainsAny(raw, "\r\n"):
		return errors.New("not one line; the envelope travels as one HTTP header")
	case !utf8.Valid(raw):
		return errors.New("invalid UTF-8")
	}
	if err := strictObject(raw); err != nil {
		return err
	}
	inst, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		return err
	}
	if err := schema.Validate(inst); err != nil {
		return err
	}
	if payloadPath == "" {
		return nil
	}
	payload, err := os.ReadFile(payloadPath)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(payload)
	if want, got := "sha256:"+hex.EncodeToString(sum[:]), inst.(map[string]any)["payload_digest"]; got != want {
		return fmt.Errorf("payload_digest %v is not the digest of %s (%s)", got, payloadPath, want)
	}
	return nil
}

// strictObject checks what the schema cannot: one object, no key twice, nothing after
// it, and integers without fraction or exponent within the decoder's bit sizes.
func strictObject(raw []byte) error {
	dec := json.NewDecoder(bytes.NewReader(raw))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return errors.New("not a JSON object")
	}
	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		key, _ := tok.(string)
		if seen[key] {
			return fmt.Errorf("%s: duplicate key", key)
		}
		seen[key] = true
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return err
		}
		if bits, ok := integerBits[key]; ok {
			if _, err := strconv.ParseInt(string(value), 10, bits); err != nil {
				return fmt.Errorf("%s: not an integer without fraction or exponent within %d bits", key, bits)
			}
		}
	}
	if _, err := dec.Token(); err != nil { // the closing brace
		return err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return errors.New("trailing data after the object")
	}
	return nil
}
