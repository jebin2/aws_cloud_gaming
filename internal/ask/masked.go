package ask

import (
	"errors"
	"io"
	"os"
	"strings"

	"golang.org/x/term"
)

// MaskedRead reads what is typed or pasted, writing a * for each character. A
// plain hidden read shows nothing at all, so a pasted key looks as if the paste
// had failed. Backspace works. Escape sequences - the bracketed-paste markers
// some terminals wrap a paste in, arrow keys - are skipped, so they are neither
// shown nor kept. It returns io.EOF at end of input with nothing typed.
func MaskedRead(in io.Reader, w io.Writer) (string, error) {
	var v []rune
	buf := make([]byte, 1)
	esc := false
	for {
		if _, err := in.Read(buf); err != nil {
			if len(v) == 0 {
				return "", io.EOF
			}
			return string(v), nil
		}
		c := buf[0]
		if esc {
			if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '~' {
				esc = false
			}
			continue
		}
		switch c {
		case '\r', '\n':
			return string(v), nil
		case 0x1b:
			esc = true
		case 0x03:
			return "", errors.New("interrupted")
		case 0x04:
			if len(v) == 0 {
				return "", io.EOF
			}
		case 0x7f, 0x08:
			if len(v) > 0 {
				v = v[:len(v)-1]
				io.WriteString(w, "\b \b")
			}
		default:
			if c >= 0x20 {
				v = append(v, rune(c))
				io.WriteString(w, "*")
			}
		}
	}
}

// readMasked is MaskedRead on the terminal, which it puts in raw mode for the
// length of the read.
func readMasked(w io.Writer) (string, error) {
	fd := int(os.Stdin.Fd())
	old, err := term.MakeRaw(fd)
	if err != nil {
		b, err := term.ReadPassword(fd)
		return strings.TrimSpace(string(b)), err
	}
	defer term.Restore(fd, old)
	return MaskedRead(os.Stdin, w)
}
