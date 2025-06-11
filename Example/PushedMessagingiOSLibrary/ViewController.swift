import UIKit
import PushedMessagingiOSLibrary

class ViewController: UIViewController {
    
    @IBOutlet weak var logoImageView: UIImageView!
    @IBOutlet weak var serviceStatusLabel: UILabel!
    @IBOutlet weak var clientTokenLabel: UILabel!
    @IBOutlet weak var copyTokenButton: UIButton!
    
    // New button for clearing token - added programmatically
    private var clearTokenButton: UIButton!
    
    private var retryCount = 0
    private let maxRetryCount = 5
    
    private var clientToken: String? {
        return PushedMessagingiOSLibrary.clientToken
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupClearTokenButton()
        updateTokenDisplay()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateTokenDisplay()
    }
    
    private func setupUI() {
        // Setup background
        view.backgroundColor = .black
        
        // Setup logo placeholder
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.tintColor = .white
        // Set placeholder image or leave empty for now
        logoImageView.image = UIImage(named: "pushed-logo") // Will be added later
        
        // Setup service status - initial loading state
        updateServiceStatus(.loading)
        serviceStatusLabel.font = UIFont.systemFont(ofSize: 24, weight: .medium)
        serviceStatusLabel.textAlignment = .center
        
        // Setup client token label
        clientTokenLabel.textColor = .lightGray
        clientTokenLabel.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        clientTokenLabel.textAlignment = .center
        clientTokenLabel.numberOfLines = 0
        clientTokenLabel.text = "Loading..."
        
        // Setup copy button - use compatible colors
        if #available(iOS 13.0, *) {
            copyTokenButton.backgroundColor = UIColor.systemGray6
        } else {
            copyTokenButton.backgroundColor = UIColor(white: 0.33, alpha: 1.0)
        }
        copyTokenButton.setTitleColor(.black, for: .normal)
        copyTokenButton.layer.cornerRadius = 8
        copyTokenButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        copyTokenButton.setTitle("📋 Copy token", for: .normal)
    }
    
    private func setupClearTokenButton() {
        // Create clear token button programmatically
        clearTokenButton = UIButton(type: .system)
        clearTokenButton.translatesAutoresizingMaskIntoConstraints = false
        
        // Style the button
        if #available(iOS 13.0, *) {
            clearTokenButton.backgroundColor = UIColor.systemRed
        } else {
            clearTokenButton.backgroundColor = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
        }
        clearTokenButton.setTitleColor(.white, for: .normal)
        clearTokenButton.layer.cornerRadius = 8
        clearTokenButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        clearTokenButton.setTitle("🔄 Reset Token", for: .normal)
        
        // Add target action
        clearTokenButton.addTarget(self, action: #selector(clearTokenTapped), for: .touchUpInside)
        
        // Add to view
        view.addSubview(clearTokenButton)
        
        // Setup constraints relative to copyTokenButton
        NSLayoutConstraint.activate([
            clearTokenButton.leadingAnchor.constraint(equalTo: copyTokenButton.leadingAnchor),
            clearTokenButton.trailingAnchor.constraint(equalTo: copyTokenButton.trailingAnchor),
            clearTokenButton.topAnchor.constraint(equalTo: copyTokenButton.bottomAnchor, constant: 16),
            clearTokenButton.heightAnchor.constraint(equalTo: copyTokenButton.heightAnchor)
        ])
    }
    
    private enum ServiceStatus {
        case loading
        case active
        case notActive
    }
    
    private func updateServiceStatus(_ status: ServiceStatus) {
        switch status {
        case .loading:
            serviceStatusLabel.text = "Загрузка"
            serviceStatusLabel.textColor = .lightGray
        case .active:
            serviceStatusLabel.text = "Active"
            if #available(iOS 13.0, *) {
                serviceStatusLabel.textColor = .systemGreen
            } else {
                serviceStatusLabel.textColor = UIColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1.0)
            }
        case .notActive:
            serviceStatusLabel.text = "Not Active"
            if #available(iOS 13.0, *) {
                serviceStatusLabel.textColor = .systemRed
            } else {
                serviceStatusLabel.textColor = UIColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
            }
        }
    }
    
    private func updateTokenDisplay() {
        if let token = clientToken, !token.isEmpty {
            // Token successfully received
            clientTokenLabel.text = token
            copyTokenButton.isEnabled = true
            copyTokenButton.alpha = 1.0
            clearTokenButton.isEnabled = true
            clearTokenButton.alpha = 1.0
            updateServiceStatus(.active)
            retryCount = 0 // Reset retry count on success
        } else {
            // Token not available
            clientTokenLabel.text = "Token not available"
            copyTokenButton.isEnabled = false
            copyTokenButton.alpha = 0.5
            clearTokenButton.isEnabled = false
            clearTokenButton.alpha = 0.5
            
            if retryCount < maxRetryCount {
                // Still trying to get token - show loading
                updateServiceStatus(.loading)
                retryCount += 1
                
                // Try to get token again after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.updateTokenDisplay()
                }
            } else {
                // Max retries exceeded - show not active
                updateServiceStatus(.notActive)
                clientTokenLabel.text = "Failed to get token"
                
                // Still keep trying in background with longer intervals
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    self.retryCount = 0 // Reset counter for background retries
                    self.updateTokenDisplay()
                }
            }
        }
    }
    
    @IBAction func copyTokenTapped(_ sender: UIButton) {
        guard let token = clientToken else { return }
        
        UIPasteboard.general.string = token
        
        // Show feedback
        let originalTitle = sender.title(for: .normal)
        sender.setTitle("✓ Copied!", for: .normal)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sender.setTitle(originalTitle, for: .normal)
        }
    }
    
    @objc private func clearTokenTapped() {
        // Show confirmation alert
        let alert = UIAlertController(title: "Reset Token", 
                                    message: "This will clear the current token and create a new one. Continue?", 
                                    preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in
            self.performTokenReset()
        })
        
        present(alert, animated: true)
    }
    
    private func performTokenReset() {
        // Update UI to show resetting state
        updateServiceStatus(.loading)
        clientTokenLabel.text = "Resetting token..."
        copyTokenButton.isEnabled = false
        copyTokenButton.alpha = 0.5
        clearTokenButton.isEnabled = false
        clearTokenButton.alpha = 0.5
        
        // Show feedback on clear button
        let originalTitle = clearTokenButton.title(for: .normal)
        clearTokenButton.setTitle("🔄 Resetting...", for: .normal)
        
        // Clear the existing token
        PushedMessagingiOSLibrary.clearTokenForTesting()
        
        // Reset retry count and trigger new token generation
        retryCount = 0
        
        // Register for remote notifications again to trigger token generation
        UIApplication.shared.registerForRemoteNotifications()
        
        // Wait a bit and then start checking for new token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.clearTokenButton.setTitle(originalTitle, for: .normal)
            self.updateTokenDisplay()
        }
    }
}

extension ViewController {
    // This method can be called when the Pushed library is initialized
    @objc func isPushedInited(didRecievePushedClientToken pushedToken: String) {
        print("Pushed token received in ViewController")
        DispatchQueue.main.async {
            self.retryCount = 0 // Reset retry count on successful token receipt
            self.updateTokenDisplay()
        }
    }
}

