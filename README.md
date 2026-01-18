# 介绍
该项目下有两个文件夹，一个为create_nuScenes_in_carla，一个为docker-monitor，前者用于生成数据，后者用于监控docker容器，并生成数据

# 环境准备
## Python环境
Python版本为3.7.6
```
pip install -r requirements.txt
```
## Carla安装
在 https://github.com/carla-simulator/carla/releases 寻找对应版本的Carla，注意版本号为**0.9.15**

## ScenarioRunner安装
在 https://github.com/carla-simulator/scenario_runner/releases 下载Carla版本为**0.9.15**的ScenarioRunner

## setup.sh脚本
按照你下载的目录修改[setup.sh](./setup.sh)脚本如下两行
```
export SRUNNER_PATH=/your/path/to/scenario_runner
export CARLA_ROOT=/your/path/to/carla/PythonAPI/carla
```
注意：CARLA_ROOT为Carla安装目录下的PythonAPI/carla目录

# 运行
1. 运行Carla
```
cd /your/path/to/carla  # 进入Carla安装目录
./CarlaUE4.sh -prefernvidia     # 如果要在无GUI的服务器上运行，增加 -RenderOffScreen
```
2. 运行scenario_runner
```
source setup.sh
cd /your/path/to/scenario_runner
python scenario_runner.py --openscenario srunner/examples/FollowLeadingVehicle.xosc # xosc代表OpenSCENARIO1.0版本的文件
```
3. 运行收集数据的脚本
```
source setup.sh
cd create_nuScenes_in_carla
python collect.py --sync --res 1600x900 -d destination.json

# 如果要在无GUI的服务器上运行，替换为
python collect_offscreen.py --sync -d destination.json
```
4. 训练及开环测试过程
```
按照Bench2DriveZoo的uniad训练流程，链接如下
https://github.com/Thinklab-SJTU/Bench2DriveZoo/blob/uniad/vad/docs/TRAIN_EVAL.md

该文件夹下的执行脚本是docker-monitor/main-zyd.sh
```
# 监控脚本
**资源监控逻辑脚本**
monitor_resources.sh
**渲染资源监控脚本**
monitor_render.sh
**训练资源监控脚本**
main-zyd.sh
# 监控命令行
**渲染及其资源监控命令行**
nohup bash -c 'cd /root/autodl-tmp/docker-monitor && bash ./monitor_render.sh 1 render_1' > /dev/null 2>&1 &
**训练及其资源监控命令行**
nohup bash -c 'cd ~/autodl-tmp/docker-monitor && bash ./monitor_train.sh train_01' > /dev/null 2>&1 &
# 监控逻辑解释
CPU和内存监控是依靠autodl容器的cgroup，GPU监控依赖于英伟达官方的nvidia-smi命令。
CPU监控的是CPU使用总量(末状态-初状态就可以得到过程CPU使用量)，内存读取的是实时占用内存量。GPU监控的是实时GPU使用率。
结果输出例子为：
```
timestamp,training_time_seconds,cpu_usage_total_seconds,gpu_utilization_total(%),gpu_memory_total_mb,memory_usage_total_mb
2026-01-06 16:12:03,2,389.6200,0.0,1,78649
2026-01-06 16:12:06,5,813.1600,0.0,330,78964
2026-01-06 16:12:08,7,1236.4100,12.0,686,80991
2026-01-06 16:12:10,9,1660.3000,8.0,1673,83602
```
# 监控逻辑不足及适配性分析
上面的监控逻辑是在autodl算力服务器上的，还没有在自己创的docker容器中跑过。据了解，虽然autodl本质是容器，但是上面的代码逻辑直接在docker容器上可能跑不了。主要原因是因为现在docker容器多使用Cgroup v2，上面脚本主要使用的是autodl中的Cgroup v1。所以要在docker容器上跑，CPU和内存监控的逻辑需要修改。GPU监控部分可能可以直接用。而且软工项目为了方便，代码中我写了降级到宿主机，好像该仓库软工项目脚本运行结果中的CPU和内存是统计的宿主机整个的CPU和内存使用情况。该仓库脚本只是提供一个监控思路，实际用docker容器代码要改的其实还是挺多的。