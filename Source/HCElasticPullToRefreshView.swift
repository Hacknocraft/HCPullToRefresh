/*

The MIT License (MIT)

Copyright (c) 2017 Hao Wang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

import UIKit

// MARK: -
// MARK: HCElasticPullToRefreshState

public
enum HCElasticPullToRefreshState: Int {
    case stopped
    case dragging
    case animatingBounce
    case loading
    case animatingToStopped

    func isAnyOf(_ values: [HCElasticPullToRefreshState]) -> Bool {
        return values.contains(where: { $0 == self })
    }
}

public
enum HCPullToRefreshPosition: Int {
    case top
    case bottom
}

// MARK: -
// MARK: HCElasticPullToRefreshView

open class HCElasticPullToRefreshView: UIView {

    /// Whether or not to include a wave bouncing animation
    static open var waveEnabled = true

    fileprivate var refreshPosition: HCPullToRefreshPosition
    fileprivate var minOffset: CGFloat

    // MARK: -
    // MARK: Vars

    fileprivate var _state: HCElasticPullToRefreshState = .stopped
    fileprivate(set) var state: HCElasticPullToRefreshState {
        get { return _state }
        set {
            let previousValue = state
            _state = newValue

            if previousValue == .dragging && newValue == .animatingBounce {
                loadingView?.startAnimating()
                animateBounce()
            } else if newValue == .loading && actionHandler != nil {
                actionHandler()
            } else if newValue == .animatingToStopped {
                resetScrollViewContentInset(shouldAddObserverWhenFinished: true, animated: true, completion: { [weak self] () -> Void in self?.state = .stopped })
            } else if newValue == .stopped {
                loadingView?.stopLoading()
            }
        }
    }

    fileprivate var originalContentInsetTop: CGFloat = 0.0 { didSet { layoutSubviews() } }
    fileprivate var originalContentInsetBottom: CGFloat = 0.0 { didSet { layoutSubviews() } }
    fileprivate let shapeLayer = CAShapeLayer()

    fileprivate var displayLink: CADisplayLink!

    var actionHandler: (() -> Void)!

    var loadingView: HCElasticPullToRefreshLoadingView? {
        willSet {
            loadingView?.removeFromSuperview()
            if let newValue = newValue {
                addSubview(newValue)
            }
        }
    }

    var observing: Bool = false {
        didSet {
            guard let scrollView = scrollView() else { return }
            if observing {
                scrollView.hc_addObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                scrollView.hc_addObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentInset)
                scrollView.hc_addObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.Frame)
                scrollView.hc_addObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState)
            } else {
                scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentInset)
                scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.Frame)
                scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState)
            }
        }
    }

    var fillColor: UIColor = .clear { didSet { shapeLayer.fillColor = fillColor.cgColor } }

    // MARK: Views

    fileprivate let bounceAnimationHelperView = UIView()

    fileprivate let cControlPointView = UIView()
    fileprivate let l1ControlPointView = UIView()
    fileprivate let l2ControlPointView = UIView()
    fileprivate let l3ControlPointView = UIView()
    fileprivate let r1ControlPointView = UIView()
    fileprivate let r2ControlPointView = UIView()
    fileprivate let r3ControlPointView = UIView()

    // MARK: -
    // MARK: Constructors

    init(position: HCPullToRefreshPosition? = nil) {
        self.refreshPosition = position ?? .top
        self.minOffset = self.refreshPosition == .top ?
            HCElasticPullToRefreshConstants.MinOffsetToPullTop :
            HCElasticPullToRefreshConstants.MinOffsetToPullBottom
        super.init(frame: CGRect.zero)

        displayLink = CADisplayLink(target: self, selector: #selector(HCElasticPullToRefreshView.displayLinkTick))
        displayLink.add(to: RunLoop.main, forMode: RunLoopMode.commonModes)
        displayLink.isPaused = true

        shapeLayer.backgroundColor = UIColor.clear.cgColor
        shapeLayer.fillColor = UIColor.black.cgColor
        shapeLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(shapeLayer)

        addSubview(bounceAnimationHelperView)
        addSubview(cControlPointView)
        addSubview(l1ControlPointView)
        addSubview(l2ControlPointView)
        addSubview(l3ControlPointView)
        addSubview(r1ControlPointView)
        addSubview(r2ControlPointView)
        addSubview(r3ControlPointView)

        NotificationCenter.default.addObserver(self, selector: #selector(HCElasticPullToRefreshView.applicationWillEnterForeground), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: -

    /**
    Has to be called when the receiver is no longer required. Otherwise the main loop holds a reference to the receiver which in turn will prevent the receiver from being deallocated.
    */
    func disassociateDisplayLink() {
        displayLink?.invalidate()
    }

    deinit {
        observing = false
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: -
    // MARK: Observer

    override open func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == HCElasticPullToRefreshConstants.KeyPaths.ContentOffset {
            if let newContentOffset = change?[NSKeyValueChangeKey.newKey], let scrollView = scrollView() {
                let newContentOffsetY = (newContentOffset as AnyObject).cgPointValue.y
                if state.isAnyOf([.loading, .animatingToStopped]) {
                    if newContentOffsetY < -scrollView.contentInset.top && refreshPosition == .top {
                        scrollView.contentOffset.y = -scrollView.contentInset.top
                    } else if newContentOffsetY > scrollView.contentSize.height - scrollView.frame.size.height && refreshPosition == .bottom {
                        scrollView.contentOffset.y = max(scrollView.contentSize.height - scrollView.frame.height, 0)
                    }
                } else {
                    scrollViewDidChangeContentOffset(dragging: scrollView.isDragging)
                }
                layoutSubviews()
            }
        } else if keyPath == HCElasticPullToRefreshConstants.KeyPaths.Frame {
            layoutSubviews()
        } else if keyPath == HCElasticPullToRefreshConstants.KeyPaths.PanGestureRecognizerState {
            if let gestureState = scrollView()?.panGestureRecognizer.state, gestureState.hc_isAnyOf([.ended, .cancelled, .failed]) {
                scrollViewDidChangeContentOffset(dragging: false)
            }
        }
    }

    // MARK: -
    // MARK: Notifications

    func applicationWillEnterForeground() {
        if state == .loading {
            layoutSubviews()
        }
    }

    // MARK: -
    // MARK: Methods (Public)

    fileprivate func scrollView() -> UIScrollView? {
        return superview as? UIScrollView
    }

    func stopLoading() {

        // Prevent stop close animation
        if state == .animatingToStopped || state == .stopped || state == .dragging {
            return
        }
        state = .animatingToStopped
    }

    // MARK: Methods (Private)

    fileprivate func isAnimating() -> Bool {
        return state.isAnyOf([.animatingBounce, .animatingToStopped])
    }

    fileprivate func actualContentOffsetY() -> CGFloat {
        guard let scrollView = scrollView() else { return 0.0 }
        return max(-scrollView.contentInset.top - scrollView.contentOffset.y, 0)
    }

    fileprivate func currentHeight() -> CGFloat {
        guard let scrollView = scrollView() else { return 0.0 }
        if refreshPosition == .top {
            return max(-originalContentInsetTop - scrollView.contentOffset.y, 0)
        } else {
            return max(scrollView.contentOffset.y + scrollView.frame.size.height - scrollView.contentSize.height - originalContentInsetBottom, 0)
        }
    }

    fileprivate func currentWaveHeight() -> CGFloat {
        return HCElasticPullToRefreshView.waveEnabled && refreshPosition == .top ?
        min(bounds.height / 3.0 * 1.6, HCElasticPullToRefreshConstants.WaveMaxHeight) :
        0
    }

    fileprivate func currentPath() -> CGPath {
        let width: CGFloat = scrollView()?.bounds.width ?? 0.0

        let bezierPath = UIBezierPath()
        let animating = isAnimating()

        bezierPath.move(to: CGPoint(x: 0.0, y: 0.0))
        bezierPath.addLine(to: CGPoint(x: 0.0, y: l3ControlPointView.hc_center(animating).y))
        bezierPath.addCurve(to: l1ControlPointView.hc_center(animating), controlPoint1: l3ControlPointView.hc_center(animating), controlPoint2: l2ControlPointView.hc_center(animating))
        bezierPath.addCurve(to: r1ControlPointView.hc_center(animating), controlPoint1: cControlPointView.hc_center(animating), controlPoint2: r1ControlPointView.hc_center(animating))
        bezierPath.addCurve(to: r3ControlPointView.hc_center(animating), controlPoint1: r1ControlPointView.hc_center(animating), controlPoint2: r2ControlPointView.hc_center(animating))
        bezierPath.addLine(to: CGPoint(x: width, y: 0.0))

        bezierPath.close()
        return bezierPath.cgPath
    }

    fileprivate func scrollViewDidChangeContentOffset(dragging: Bool) {
        let offsetY = actualContentOffsetY()

        guard let scrollView = scrollView() else { return }

        if state == .stopped && dragging {
            state = .dragging
        } else if state == .dragging && dragging == false {
            if (refreshPosition == .top &&
                offsetY >= minOffset) ||
                (refreshPosition == .bottom &&
                scrollView.contentOffset.y + scrollView.frame.size.height - scrollView.contentSize.height >= minOffset &&
                scrollView.hasMoreContentThanHeight()) {
                state = .animatingBounce
            } else {
                state = .stopped
            }
        } else if state.isAnyOf([.dragging, .stopped]) {
            let draggingDistance = refreshPosition == .top ?
                offsetY : scrollView.contentOffset.y - (scrollView.contentSize.height - scrollView.frame.size.height)
            let pullProgress: CGFloat = draggingDistance / minOffset
            loadingView?.setPullProgress(pullProgress)
        }
    }

    fileprivate func resetScrollViewContentInset(shouldAddObserverWhenFinished: Bool, animated: Bool, completion: (() -> Void)?) {
        guard let scrollView = scrollView() else { return }

        var contentInset = scrollView.contentInset
        contentInset.top = originalContentInsetTop
        contentInset.bottom = originalContentInsetBottom

        if state == .animatingBounce {
            if refreshPosition == .top {
                contentInset.top += currentHeight()
            } else {
                contentInset.bottom += currentHeight()
            }
        } else if state == .loading {
            if refreshPosition == .top {
                contentInset.top += HCElasticPullToRefreshConstants.LoadingContentInset
            } else {
                contentInset.bottom += HCElasticPullToRefreshConstants.LoadingContentInset
            }
        }

        scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentInset)

        let animationBlock = {
            scrollView.contentInset = contentInset
        }
        let completionBlock = { () -> Void in
            if shouldAddObserverWhenFinished && self.observing {
                scrollView.hc_addObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentInset)
            }
            completion?()
        }

        if animated {
            startDisplayLink()
            UIView.animate(withDuration: 0.4, animations: animationBlock, completion: { _ in
                self.stopDisplayLink()
                completionBlock()
            })
        } else {
            animationBlock()
            completionBlock()
        }
    }

    fileprivate func animateBounce() {
        guard let scrollView = scrollView() else { return }
        if (!self.observing) { return }

        resetScrollViewContentInset(shouldAddObserverWhenFinished: false, animated: false, completion: nil)

        let duration = 0.9
        let centerY = HCElasticPullToRefreshConstants.LoadingContentInset

        scrollView.isScrollEnabled = false
        startDisplayLink()
        scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentOffset)
        scrollView.hc_removeObserver(self, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentInset)

        UIView.animate(withDuration: duration, delay: 0.0, usingSpringWithDamping: 0.43, initialSpringVelocity: 0.0, options: [], animations: { [weak self] in

            let y = self?.refreshPosition == .top ? centerY : centerY + 100
            self?.cControlPointView.center.y = y
            self?.l1ControlPointView.center.y = y
            self?.l2ControlPointView.center.y = y
            self?.l3ControlPointView.center.y = y
            self?.r1ControlPointView.center.y = y
            self?.r2ControlPointView.center.y = y
            self?.r3ControlPointView.center.y = y
            }, completion: { [weak self] _ in
                self?.stopDisplayLink()
                self?.resetScrollViewContentInset(shouldAddObserverWhenFinished: true, animated: false, completion: nil)
                if let strongSelf = self, let scrollView = strongSelf.scrollView() {
                    scrollView.hc_addObserver(strongSelf, forKeyPath: HCElasticPullToRefreshConstants.KeyPaths.ContentOffset)
                    scrollView.isScrollEnabled = true
                }
                self?.state = .loading
            })

        if refreshPosition == .top {
            bounceAnimationHelperView.center = CGPoint(x: 0.0, y: originalContentInsetTop + currentHeight())
        } else {
            bounceAnimationHelperView.center = CGPoint(x: 0.0, y: scrollView.contentSize.height - currentHeight())
        }
        UIView.animate(withDuration: duration * 0.4, animations: { [weak self] in

            if let contentInsetTop = self?.originalContentInsetTop, self?.refreshPosition == .top {
                self?.bounceAnimationHelperView.center = CGPoint(x: 0.0, y: contentInsetTop + HCElasticPullToRefreshConstants.LoadingContentInset)
            } else if self?.refreshPosition == .bottom {
                self?.bounceAnimationHelperView.center = CGPoint(x: 0.0, y: scrollView.contentSize.height - HCElasticPullToRefreshConstants.LoadingContentInset)
            }
            }, completion: nil)
    }

    // MARK: -
    // MARK: CADisplayLink

    fileprivate func startDisplayLink() {
        displayLink.isPaused = false
    }

    fileprivate func stopDisplayLink() {
        displayLink.isPaused = true
    }

    func displayLinkTick() {
        let width = bounds.width
        var height: CGFloat = 0.0
        guard let scrollView = scrollView() else { return }

        if state == .animatingBounce {

            if refreshPosition == .top {
                scrollView.contentInset.top = bounceAnimationHelperView.hc_center(isAnimating()).y
                scrollView.contentOffset.y = -scrollView.contentInset.top

                height = scrollView.contentInset.top - originalContentInsetTop

                frame = CGRect(x: 0.0, y: -height - 1.0, width: width, height: height)
            } else {
                scrollView.contentInset.bottom = bounceAnimationHelperView.hc_center(isAnimating()).y > 0 ?
                    scrollView.contentSize.height - bounceAnimationHelperView.hc_center(isAnimating()).y :
                    0
                scrollView.contentOffset.y = max(scrollView.contentSize.height - scrollView.frame.height, 0) + scrollView.contentInset.bottom

                height = scrollView.contentInset.bottom - originalContentInsetBottom

                frame = CGRect(x: 0.0, y: max(scrollView.contentSize.height, scrollView.frame.size.height), width: width, height: height)
            }

        } else if state == .animatingToStopped {
            height = actualContentOffsetY()
        }

        shapeLayer.frame = CGRect(x: 0.0, y: 0.0, width: width, height: height)
        shapeLayer.path = currentPath()

        layoutLoadingView()
    }

    // MARK: -
    // MARK: Layout

    fileprivate func layoutLoadingView() {
        let width = bounds.width
        let height: CGFloat = bounds.height

        let loadingViewSize: CGFloat = HCElasticPullToRefreshConstants.LoadingViewSize
        let minOriginY = (HCElasticPullToRefreshConstants.LoadingContentInset - loadingViewSize) / 2.0
        let originY: CGFloat = max(min((height - loadingViewSize) / 2.0, minOriginY), 0.0)

        loadingView?.frame = CGRect(x: (width - loadingViewSize) / 2.0, y: originY, width: loadingViewSize, height: loadingViewSize)
        loadingView?.maskLayer.frame = convert(shapeLayer.frame, to: loadingView)
        loadingView?.maskLayer.path = shapeLayer.path
    }

    override open func layoutSubviews() {
        super.layoutSubviews()

        if let scrollView = scrollView(), state != .animatingBounce {
            let width = scrollView.bounds.width
            let contentHeight = max(scrollView.frame.size.height, scrollView.contentSize.height)
            let height = currentHeight()

            // position of the refresh view depends on where it's added
            let yPosition = refreshPosition == .top ?
                -height : contentHeight

            frame = CGRect(x: 0.0, y: yPosition, width: width, height: height)

            if state.isAnyOf([.loading, .animatingToStopped]) {

                let centerY = refreshPosition == .top ? height : 0
                cControlPointView.center = CGPoint(x: width / 2.0, y: centerY)
                l1ControlPointView.center = CGPoint(x: 0.0, y: centerY)
                l2ControlPointView.center = CGPoint(x: 0.0, y: centerY)
                l3ControlPointView.center = CGPoint(x: 0.0, y: centerY)
                r1ControlPointView.center = CGPoint(x: width, y: centerY)
                r2ControlPointView.center = CGPoint(x: width, y: centerY)
                r3ControlPointView.center = CGPoint(x: width, y: centerY)
            } else {
                let locationX = scrollView.panGestureRecognizer.location(in: scrollView).x

                let waveHeight = currentWaveHeight()
                let baseHeight = bounds.height - waveHeight

                let minLeftX = min((locationX - width / 2.0) * 0.28, 0.0)
                let maxRightX = max(width + (locationX - width / 2.0) * 0.28, width)

                let leftPartWidth = locationX - minLeftX
                let rightPartWidth = maxRightX - locationX

                let direction: CGFloat = refreshPosition == .top ? 1 : -1

                cControlPointView.center = CGPoint(x: locationX,
                                                   y: baseHeight + waveHeight * 1.36 * direction)
                l1ControlPointView.center = CGPoint(x: minLeftX + leftPartWidth * 0.71,
                                                    y: baseHeight + waveHeight * 0.64 * direction)
                l2ControlPointView.center = CGPoint(x: minLeftX + leftPartWidth * 0.44,
                                                    y: baseHeight)
                l3ControlPointView.center = CGPoint(x: minLeftX,
                                                    y: baseHeight)
                r1ControlPointView.center = CGPoint(x: maxRightX - rightPartWidth * 0.71,
                                                    y: baseHeight + waveHeight * 0.64 * direction)
                r2ControlPointView.center = CGPoint(x: maxRightX - (rightPartWidth * 0.44),
                                                    y: baseHeight)
                r3ControlPointView.center = CGPoint(x: maxRightX,
                                                    y: baseHeight)
            }

            shapeLayer.frame = CGRect(x: 0.0, y: 0.0, width: width, height: height)
            shapeLayer.path = currentPath()

            layoutLoadingView()
        }
    }

}
