## Freetoken fails on my desktop (which has two Nvidia cards).
When the model is launched, the wrong GPU is used even though the correct one is specified with the `--gpu` option. In my specific case, 
the NVIDIA 4060 Ti is used, which is unable to handle gpt-oss-120b MXFP4 (the 5060 Ti’s Blackwell processor is required for MXFP4). 
I found that by setting an appropriate environment variable to force the use of the 5060 and removing the —gpu option, 
everything worked correctly for this specific model.

To apply the patch:
```
install -m 755 ~/Scaricati/ft-gpu-patch.sh /<PATH_CONFIGURED_IN_THE_DEKSTOP_APP>/freetoken/ft-gpu-patch.sh

/<PATH_CONFIGURED_IN_THE_DEKSTOP_APP>/freetoken/ft-gpu-patch.sh apply

FT_GPU_PATCH_DRYRUN=1 /<PATH_CONFIGURED_IN_THE_DEKSTOP_APP>/freetoken/venv/bin/ft serve --model /<PATH_CONFIGURED_IN_THE_DEKSTOP_APP>/freetoken/gpt-oss-120b \
  --port 1919 --gpu GPU-de110751-309a-0814-d910-623f85e22787
```
This should print the correct command line without `--gpu` and with `CUDA_VISIBLE_DEVICES=GPU-de110751-309a-0814-d910-623f85e22787` 
just before the `ft serve` command.
