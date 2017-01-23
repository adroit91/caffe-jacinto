#include "caffe/quantized_layer.hpp"
#include "caffe/quantized_layer.cuh"

namespace caffe {


template<typename Dtype>
void QuantizedLayer<Dtype>::Quantize_gpu(const vector<Blob<Dtype>*>& bottom,
    const vector<Blob<Dtype>*>& top) {
  if (this->layer_param_.has_quantization_param()) {
    //LOG(INFO) << "Quantizing layer: " << this->layer_param_.name();
    const vector<shared_ptr<Blob<Dtype> > >& blobs = this->blobs();
    const QuantizationParameter& param = this->layer_param_.quantization_param();
    if (param.precision() != QuantizationParameter_Precision_FLOAT) {
      // Trim layer input
      if(param.quantize_layer_in()) {
        for (int i = 0; i < bottom.size(); ++i) {
          this->QuantizeLayerInputs_gpu(bottom[i]->mutable_gpu_data(), i, bottom[i]->count());
        }
      }

      // Trim weights
      if(param.quantize_layer_weights() && blobs.size() > 0) {
        this->QuantizeWeights_gpu(blobs[0]->mutable_gpu_data(), blobs[0]->count(), param.rounding_scheme(), true);
        if (blobs.size() > 1) { //(this->bias_term_) {
          this->QuantizeWeights_gpu(blobs[1]->mutable_gpu_data(), blobs[1]->count(), param.rounding_scheme(), false);
        }
      }

      // Trim layer output
      if(param.quantize_layer_out()) {
        for (int i = 0; i < top.size(); ++i) {
          this->QuantizeLayerOutputs_gpu(top[i]->mutable_gpu_data(), top[i]->count());
        }
      }
    }
  }
}


template <typename Dtype>
void QuantizedLayer<Dtype>::QuantizeWeights_gpu(Dtype* data, const int count, const int rounding, bool clip) {
  const QuantizationParameter& param = this->layer_param_.quantization_param();
  switch (param.precision()) {
  case QuantizationParameter_Precision_MINIFLOAT:
    Trim2MiniFloat_gpu(data, count, param.mant_bits(), param.exp_bits(), param.rounding_scheme());
    break;
  case QuantizationParameter_Precision_DYNAMIC_FIXED_POINT:
    Trim2FixedPoint_gpu(data, count, param.bw_weights(), param.rounding_scheme(), param.fl_weights(),
    		0, false, clip);
    break;
  case QuantizationParameter_Precision_INTEGER_POWER_OF_2_WEIGHTS:
    Trim2IntegerPowerOf2_gpu(data, count, param.exp_min(), param.exp_max(),
        rounding);
    break;
  case QuantizationParameter_Precision_FLOAT:
	  break;
  default:
    LOG(FATAL) << "Unknown trimming mode: " << param.precision() << " for layer:" << this->layer_param_.name();
    break;
  }
}

template <typename Dtype>
void QuantizedLayer<Dtype>::QuantizeLayerInputs_gpu(
    Dtype* data, const int blob_id, const int count) {
  const QuantizationParameter& param = this->layer_param_.quantization_param();
  bool unsigned_layer_in = param.unsigned_layer_in_size()>0? param.unsigned_layer_in(blob_id): false;
  switch (param.precision()) {
    case QuantizationParameter_Precision_INTEGER_POWER_OF_2_WEIGHTS:
    case QuantizationParameter_Precision_DYNAMIC_FIXED_POINT:
      if(param.fl_layer_in_size() > blob_id) {
        Trim2FixedPoint_gpu(data, count, param.bw_layer_in(), param.rounding_scheme(), param.fl_layer_in(blob_id),
    		  0, unsigned_layer_in, true);
      }
      break;
    case QuantizationParameter_Precision_MINIFLOAT:
      Trim2MiniFloat_gpu(data, count, param.mant_bits(), param.exp_bits(), param.rounding_scheme());
      break;
    case QuantizationParameter_Precision_FLOAT:
  	  break;
    default:
      LOG(FATAL) << "Unknown trimming mode: " << param.precision() << " for layer:" << this->layer_param_.name();
      break;
  }
}

template <typename Dtype>
void QuantizedLayer<Dtype>::QuantizeLayerOutputs_gpu(Dtype* data,
      const int count) {
  const QuantizationParameter& param = this->layer_param_.quantization_param();
  switch (param.precision()) {
    case QuantizationParameter_Precision_INTEGER_POWER_OF_2_WEIGHTS:
    case QuantizationParameter_Precision_DYNAMIC_FIXED_POINT:
      Trim2FixedPoint_gpu(data, count, param.bw_layer_out(), param.rounding_scheme(), param.fl_layer_out(),
    		  0, param.unsigned_layer_out(), true);
      break;
    case QuantizationParameter_Precision_MINIFLOAT:
      Trim2MiniFloat_gpu(data, count, param.mant_bits(), param.exp_bits(), param.rounding_scheme());
      break;
    case QuantizationParameter_Precision_FLOAT:
  	  break;
    default:
      LOG(FATAL) << "Unknown trimming mode: " << param.precision() << " for layer:" << this->layer_param_.name();
      break;
  }
}

template <typename Dtype>
__global__ void Trim2FixedPoint_kernel(Dtype* data, const int cnt,
      const int bit_width, const int rounding, const int fl, Dtype sparsity_threshold, bool unsigned_data, bool clip) {
	CUDA_KERNEL_LOOP(index, cnt) {
    
    data[index] = data[index] * powf(2, fl);

    // Round data
    switch (rounding) {
    case QuantizationParameter_Rounding_NEAREST:
      data[index] = rint(data[index]);
      break;
    case QuantizationParameter_Rounding_STOCHASTIC:
      data[index] = __float2int_rd(data[index] + RandUniform_device(index));
      break;
    default:
      break;
    }

#if CLIP_QUANT
    if(clip) {
    	// Saturate data
    	int qrange = unsigned_data? bit_width :  (bit_width - 1);
    	Dtype max_data = +(powf(2, qrange) - 1);
    	Dtype min_data = unsigned_data? 0 : -(powf(2, qrange));
    	data[index] = (data[index]>max_data?max_data:(data[index]<min_data?min_data:data[index]));
    }
#endif

    if(sparsity_threshold != 0 && fabs(data[index]) < sparsity_threshold) {
    	data[index] = 0;
    }

    data[index] = data[index] * powf(2, -fl);
  }
}

template <typename Dtype>
void QuantizedLayer<Dtype>::Trim2FixedPoint_gpu(Dtype* data, const int cnt,
      const int bit_width, const int rounding, int fl, Dtype sparsity_threshold, bool unsigned_data, bool clip) {
  Trim2FixedPoint_kernel<<<CAFFE_GET_BLOCKS(cnt), CAFFE_CUDA_NUM_THREADS>>>(
      data, cnt, bit_width, rounding, fl, sparsity_threshold, unsigned_data, clip);
}

template <typename Dtype>
__global__ void Trim2MiniFloat_kernel(Dtype* data, const int cnt,
      const int bw_mant, const int bw_exp, const int rounding){
	CUDA_KERNEL_LOOP(index, cnt) {
    Trim2MiniFloat_device(&data[index], bw_mant, bw_exp, rounding, index);
	}
}

template <typename Dtype>
void QuantizedLayer<Dtype>::Trim2MiniFloat_gpu(Dtype* data,
      const int cnt, const int bw_mant, const int bw_exp, const int rounding) {
  Trim2MiniFloat_kernel<<<CAFFE_GET_BLOCKS(cnt), CAFFE_CUDA_NUM_THREADS>>>(
      data, cnt, bw_mant, bw_exp, rounding);
}

template <typename Dtype>
__global__ void Trim2IntegerPowerOf2_kernel(Dtype* data, const int cnt,
      const int min_exp, const int max_exp, const int rounding) {
	CUDA_KERNEL_LOOP(index, cnt) {
    float exponent = log2f(fabs((float)data[index]));
    int sign = data[index] >= 0 ? 1 : -1;
    switch (rounding) {
    case QuantizationParameter_Rounding_NEAREST:
      exponent = rint(exponent);
      break;
    case QuantizationParameter_Rounding_STOCHASTIC:
      exponent = __float2int_rd(exponent + RandUniform_device(index));
      break;
    default:
      break;
    }
    exponent = fmaxf(fminf(exponent, max_exp), min_exp);
    data[index] = sign * powf(2, exponent);
	}
}

template <typename Dtype>
void QuantizedLayer<Dtype>::Trim2IntegerPowerOf2_gpu(Dtype* data,
      const int cnt, const int min_exp, const int max_exp, const int rounding) {
  Trim2IntegerPowerOf2_kernel<<<CAFFE_GET_BLOCKS(cnt), CAFFE_CUDA_NUM_THREADS>>>(
      data, cnt, min_exp, max_exp, rounding);
}



template void QuantizedLayer<float>::Quantize_gpu(const vector<Blob<float>*>& bottom, const vector<Blob<float>*>& top);
template void QuantizedLayer<double>::Quantize_gpu(const vector<Blob<double>*>& bottom, const vector<Blob<double>*>& top);

}  // namespace caffe


