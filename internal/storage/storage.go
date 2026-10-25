// Package storage finds what cg left behind in EVERY region: a region move
// leaves disks, images and snapshots where nothing looks, and they bill all the
// same. The scan asks every region at once, and a region AWS would not answer
// for is said, never read as empty.
package storage

import (
	"context"
	"sort"
	"sync"

	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
)

// Found is what one region holds.
type Found struct {
	Region    string
	Volumes   []costfacts.Volume
	Images    []costfacts.Image
	Snapshots []costfacts.Snapshot
}

// Everywhere is the whole answer.
type Everywhere struct {
	Found  []Found  // in region order
	Failed []string // the regions AWS would not answer for
}

// Scan asks every region at once.
func Scan(ctx context.Context, regions []string, gatherer func(region string) *costfacts.Gatherer) Everywhere {
	sort.Strings(regions)
	res := make([]Found, len(regions))
	failed := make([]bool, len(regions))
	var wg sync.WaitGroup
	for i, r := range regions {
		wg.Add(1)
		go func(i int, r string) {
			defer wg.Done()
			v, im, sn, err := gatherer(r).Owned(ctx)
			if err != nil {
				failed[i] = true
				return
			}
			res[i] = Found{r, v, im, sn}
		}(i, r)
	}
	wg.Wait()
	var out Everywhere
	for i, r := range regions {
		if failed[i] {
			out.Failed = append(out.Failed, r)
		} else {
			out.Found = append(out.Found, res[i])
		}
	}
	return out
}
