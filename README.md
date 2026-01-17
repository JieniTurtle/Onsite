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
4. 训练过程
```
按照Bench2DriveZoo的uniad训练流程，链接如下
https://github.com/Thinklab-SJTU/Bench2DriveZoo/blob/uniad/vad/docs/TRAIN_EVAL.md

该文件夹下的执行脚本是docker-monitor/main-zyd.sh
```
