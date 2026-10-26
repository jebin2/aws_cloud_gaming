package games

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// VolumeDeleter is what deleting the legacy volume uses.
type VolumeDeleter interface {
	DeleteVolume(context.Context, *ec2.DeleteVolumeInput, ...func(*ec2.Options)) (*ec2.DeleteVolumeOutput, error)
}

// DeleteVolume is `cg games --volume --delete`: nothing uses the volume any more,
// the games are in S3, and it bills whether or not a box exists. It refuses unless
// the volume is available (attached to nothing), and asks for the word.
func DeleteVolume(ctx context.Context, c VolumeDeleter, v *Volume, a *ask.Asker, out *output.Out) int {
	if v == nil {
		out.Echo("no EBS game volume exists - nothing billing.")
		out.Echo("the game library lives in S3 now: cg library")
		return 0
	}
	if v.State != "available" {
		out.Die(fmt.Sprintf("volume is %s - stop or destroy the instance first", v.State))
		return 1
	}
	out.Echo("Nothing uses this volume any more; the games are in S3 (cg library).")
	out.Echo(fmt.Sprintf("This permanently deletes %s and every game on it.", v.ID))
	if !a.Typed("delete-volume", "type DELETE to confirm: ", "DELETE") {
		out.Echo("aborted")
		return 1
	}
	if _, err := c.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: aws.String(v.ID)}); err != nil {
		out.Die("could not delete " + v.ID + ": " + err.Error())
		return 1
	}
	out.Log("deleted " + v.ID)
	out.Log("storage charges stop now")
	return 0
}
