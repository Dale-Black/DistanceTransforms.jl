module DistanceTransforms

using ImageEdgeDetection
using ImageMorphology: feature_transform, distance_transform
using Tullio
using Statistics
using Distances

include("./losses.jl")
include("./metrics.jl")
include("./utils.jl")

export 
    # Export losses.jl functions
    dice_loss,
    hd_loss,
    dice_lossP,
    hd_lossP,

    # Export metrics.jl functions
    dice_metric,
    mean_hausdorff_2D,

    # Export utils.jl functions
    detect_edges_3D,
    compute_dtm

end
