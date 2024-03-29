using GPUArraysCore: AbstractGPUVector, AbstractGPUMatrix, AbstractGPUArray
using KernelAbstractions

"""
## `transform!`

```julia
transform!(f::AbstractVector, output, v, z)
transform!(img::AbstractMatrix, output, v, z; threaded=true)
transform!(vol::AbstractArray{<:Real,3}, output, v, z, temp; threaded=true)
transform!(img::AbstractGPUMatrix, output, v, z)
```
In-place squared Euclidean distance transforms. These functions apply the transform to the input data and store the result in the `output` argument.

- The first function operates on vectors.
- The second function operates on matrices with optional threading.
- The third function operates on 3D arrays with optional threading.
- The fourth function is specialized for GPU matrices.

The intermediate arrays `v` and `z` (and `temp` for 3D arrays) are used for computation. The `threaded` parameter enables parallel computation on the CPU.

#### Arguments
- `f`: Input vector, matrix, or 3D array.
- `output`: Preallocated array to store the result.
- `v`: Preallocated array for indices, matching the dimensions of `f`.
- `z`: Preallocated array for intermediate values, one element larger than `f`.
- `temp`: Preallocated array for intermediate values when transforming 3D arrays, matching the dimensions of `output`.

#### Examples
```julia
f = rand([0f0, 1f0], 10)
f_bool = boolean_indicator(f)
output = similar(f)
v = ones(Int32, size(f))
z = ones(eltype(f), size(f) .+ 1)
transform!(f_bool, output, v, z)
```
"""
function transform!(f::AbstractVector, output, v, z)
	z[1] = -Inf32
	z[2] = Inf32

	k = 1
	@inbounds for q in 2:length(f)
		s = ((f[q] + q^2) - (f[v[k]] + v[k]^2)) / (2 * q - 2 * v[k])
		while s ≤ z[k]
			k -= 1
			s = ((f[q] + q^2) - (f[v[k]] + v[k]^2)) / (2 * q - 2 * v[k])
		end
		k += 1
		v[k] = q
		z[k] = s
		z[k+1] = Inf32
	end

	k = 1
	@inbounds for q in 1:length(f)
		while z[k+1] < q
			k += 1
		end
		output[q] = (q - v[k])^2 + f[v[k]]
	end
end

# 2D
function transform!(img::AbstractMatrix, output, v, z; threaded = true)
	if threaded
		Threads.@threads for i in CartesianIndices(@view(img[:, 1]))
			@views transform!(img[i, :], output[i, :], v[i, :], z[i, :])
		end

		copyto!(img, output)
		Threads.@threads for j in CartesianIndices(@view(img[1, :]))
			@views transform!(
				img[:, j], output[:, j], fill!(v[:, j], 1), fill!(z[:, j], 1),
			)
		end
	else
		for i in CartesianIndices(@view(img[:, 1]))
			@views transform!(img[i, :], output[i, :], v[i, :], z[i, :])
		end

		copyto!(img, output)
		for j in CartesianIndices(@view(img[1, :]))
			@views transform!(
				img[:, j], output[:, j], fill!(v[:, j], 1), fill!(z[:, j], 1),
			)
		end
	end
end

# 3D
function transform!(vol::AbstractArray{<:Real, 3}, output, v, z; threaded = true)
	if threaded
		Threads.@threads for i in CartesianIndices(@view(vol[:, 1, 1]))
			@views transform!(vol[i, :, :], output[i, :, :], v[i, :, :], z[i, :, :])
		end

		copyto!(vol, output)
		Threads.@threads for idx in CartesianIndices(@view(vol[1, :, :]))
			j, k = Tuple(idx)
			@views transform!(
				vol[:, j, k], output[:, j, k], fill!(v[:, j, k], 1), fill!(z[:, j, k], 1),
			)
		end
	else
		for i in CartesianIndices(@view(vol[:, 1, 1]))
			@views transform!(vol[i, :, :], output[i, :, :], v[i, :, :], z[i, :, :])
		end

		copyto!(vol, output)
		for idx in CartesianIndices(@view(vol[1, :, :]))
			j, k = Tuple(idx)
			@views transform!(
				vol[:, j, k], output[:, j, k], fill!(v[:, j, k], 1), fill!(z[:, j, k], 1),
			)
		end
	end
end

# GPU (2D)
@kernel function _first_pass_2D!(f, out, s2)
	row, col = @index(Global, NTuple)

	if f[row, col] < 0.5f0
		ct = 1
		curr_l = min(col - 1, s2 - col)
		finished = false
		while !finished && ct <= curr_l
			if f[row, col-ct] > 0.5f0 || f[row, col+ct] > 0.5f0
				out[row, col] = ct * ct
				finished = true
			end
			ct += 1
		end
		while !finished && ct < col
			if f[row, col-ct] > 0.5f0
				out[row, col] = ct * ct
				finished = true
			end
			ct += 1
		end
		while !finished && col + ct <= s2
			if f[row, col+ct] > 0.5f0
				out[row, col] = ct * ct
				finished = true
			end
			ct += 1
		end
		if !finished
			out[row, col] = 1.0f10
		end
	else
		out[row, col] = 0.0f0
	end
end

@kernel function _second_pass_2D!(org, out, s1, s2)
	row, col = @index(Global, NTuple)

	ct = 1
	curr_l = sqrt(out[row, col])
	while ct < curr_l && row + ct <= s1
		temp = muladd(ct, ct, org[row+ct, col])
		if temp < out[row, col]
			out[row, col] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end

	ct = 1
	while ct < curr_l && row > ct
		temp = muladd(ct, ct, org[row-ct, col])
		if temp < out[row, col]
			out[row, col] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end
end

function transform!(img::AbstractGPUMatrix, output)
	s1, s2 = size(img)
	backend = get_backend(img)
	kernel1! = _first_pass_2D!(backend)
	kernel2! = _second_pass_2D!(backend)

	kernel1!(img, output, s2, ndrange = (s1, s2))
	copyto!(img, output)

	kernel2!(img, output, s1, s2, ndrange = (s1, s2))
	KernelAbstractions.synchronize(backend)
end

# GPU (3D)
@kernel function _first_pass_3D!(f, out, s2)
	dim1, dim2, dim3 = @index(Global, NTuple)
	# 1D along dimension 2
	if f[dim1, dim2, dim3] < 0.5f0
		ct = 1
		curr_l = min(dim2 - 1, s2 - dim2)
		finished = false
		while !finished && ct <= curr_l
			if f[dim1, dim2-ct, dim3] > 0.5f0 || f[dim1, dim2+ct, dim3] > 0.5f0
				out[dim1, dim2, dim3] = ct * ct
				finished = true
			end
			ct += 1
		end
		while !finished && ct < dim2
			if f[dim1, dim2-ct, dim3] > 0.5f0
				out[dim1, dim2, dim3] = ct * ct
				finished = true
			end
			ct += 1
		end
		while !finished && dim2 + ct <= s2
			if f[dim1, dim2+ct, dim3] > 0.5f0
				out[dim1, dim2, dim3] = ct * ct
				finished = true
			end
			ct += 1
		end
		if !finished
			out[dim1, dim2, dim3] = 1.0f10
		end
	else
		out[dim1, dim2, dim3] = 0.0f0
	end
end

@kernel function _second_pass_3D!(org, out, s1)
	dim1, dim2, dim3 = @index(Global, NTuple)
	# 2D along dimension 1
	ct = 1
	curr_l = sqrt(out[dim1, dim2, dim3])
	while ct < curr_l && dim1 + ct <= s1
		temp = muladd(ct, ct, org[dim1+ct, dim2, dim3])
		if temp < out[dim1, dim2, dim3]
			out[dim1, dim2, dim3] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end
	ct = 1
	while ct < curr_l && dim1 - ct > 0
		temp = muladd(ct, ct, org[dim1-ct, dim2, dim3])
		if temp < out[dim1, dim2, dim3]
			out[dim1, dim2, dim3] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end
end

@kernel function _third_pass_3D!(org, out, s3)
	dim1, dim2, dim3 = @index(Global, NTuple)
	# 2D along dimension 3
	ct = 1
	curr_l = sqrt(out[dim1, dim2, dim3])
	while ct < curr_l && dim3 + ct <= s3
		temp = muladd(ct, ct, org[dim1, dim2, dim3+ct])
		if temp < out[dim1, dim2, dim3]
			out[dim1, dim2, dim3] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end
	ct = 1
	while ct < curr_l && ct < dim3
		temp = muladd(ct, ct, org[dim1, dim2, dim3-ct])
		if temp < out[dim1, dim2, dim3]
			out[dim1, dim2, dim3] = temp
			curr_l = sqrt(temp)
		end
		ct += 1
	end
end

function transform!(img::AbstractGPUArray, output)
	backend = get_backend(img)
	s1, s2, s3 = size(img)
	kernel1! = _first_pass_3D!(backend)
	kernel2! = _second_pass_3D!(backend)
	kernel3! = _third_pass_3D!(backend)

	kernel1!(img, output, s2, ndrange = (s1, s2, s3))
	copyto!(img, output)

	kernel2!(img, output, s1, ndrange = (s1, s2, s3))
	copyto!(img, output)

	kernel3!(img, output, s3, ndrange = (s1, s2, s3))

	KernelAbstractions.synchronize(backend)
end

export transform!

"""
## `transform`

```julia
transform(f::AbstractVector)
transform(img::AbstractMatrix; threaded=true)
transform(vol::AbstractArray{<:Real,3}; threaded=true)
transform(img::AbstractGPUMatrix)
```

Non-in-place squared Euclidean distance transforms that return a new array with the result. They allocate necessary intermediate arrays internally.

- The first function operates on vectors.
- The second function operates on matrices with optional threading.
- The third function operates on 3D arrays with optional threading.
- The fourth function is specialized for GPU matrices.

The `threaded` parameter can be used to enable or disable parallel computation on the CPU.

#### Arguments
- `f/img/vol`: Input vector, matrix, or 3D array to be transformed.

#### Examples
```julia
f = rand([0f0, 1f0], 10)
f_bool = boolean_indicator(f)
f_tfm = transform(f_bool)
```
"""
function transform(f::AbstractVector)
	output = similar(f, eltype(f))
	v = ones(Int32, length(f))
	z = ones(eltype(f), length(f) + 1)

	transform!(f, output, v, z)
	return output
end

# 2D
function transform(img::AbstractMatrix; threaded = true)
	output = similar(img, eltype(img))
	v = ones(Int32, size(img))
	z = ones(eltype(img), size(img) .+ 1)

	transform!(img, output, v, z; threaded = threaded)
	return output
end

# 3D
function transform(vol::AbstractArray{<:Real, 3}; threaded = true)
	output = similar(vol, eltype(vol))
	v = ones(Int32, size(vol))
	z = ones(eltype(vol), size(vol) .+ 1)

	transform!(vol, output, v, z; threaded = threaded)
	return output
end

# GPU (2D)
function transform(img::AbstractGPUMatrix)
	output = similar(img, Float32)
	transform!(img, output)
	return output
end

# GPU (3D)
function transform(img::AbstractGPUArray)
	output = similar(img, Float32)
	transform!(img, output)
	return output
end

export transform
