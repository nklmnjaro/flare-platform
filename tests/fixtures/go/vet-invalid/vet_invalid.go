package vetinvalid

import "fmt"

func invalidPrintf() {
	fmt.Printf("%d", "wrong-type")
}
